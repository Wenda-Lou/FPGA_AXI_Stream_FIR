`timescale 1ns/1ps
// Request-driven interface testbench. No expected arithmetic values are read.
// Payloads are driven through public AXI ports; clipping is an observation of
// the existing internal per-output flag, not a forced DUT state or sideband.
module tb_web_fir;
    logic clk=0, resetn=0;
    always #5 clk=~clk;
    logic [15:0] s_axis_tdata=0;
    logic s_axis_tvalid=0, m_axis_tready=0;
    wire s_axis_tready, m_axis_tvalid;
    wire [15:0] m_axis_tdata;
    logic [7:0] s_axi_awaddr=0, s_axi_araddr=0;
    logic [2:0] s_axi_awprot=0, s_axi_arprot=0;
    logic s_axi_awvalid=0,s_axi_wvalid=0,s_axi_bready=0,s_axi_arvalid=0,s_axi_rready=0;
    logic [31:0] s_axi_wdata=0;
    logic [3:0] s_axi_wstrb=0;
    wire s_axi_awready,s_axi_wready,s_axi_bvalid,s_axi_arready,s_axi_rvalid;
    wire [1:0] s_axi_bresp,s_axi_rresp;
    wire [31:0] s_axi_rdata;
    dsp_accelerator dut(.*);
    logic [15:0] input_words[0:9999], coefficient_words[0:7];
    integer count, input_file, output_file, summary_file;
    integer cycles=0, inputs=0, outputs=0, first_input=-1, last_output=-1;
    bit clipped=0, held=0;
    logic [16:0] held_payload;

    // Bound the whole simulation, including control channels and drain waits.
    initial begin
        repeat(200000) @(posedge clk);
        $fatal(1,"Web request simulation watchdog expired");
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if (resetn) begin
            if (held && (!m_axis_tvalid || {dut.output_saturated,m_axis_tdata} !== held_payload))
                $fatal(1,"Output payload changed under backpressure");
            held=m_axis_tvalid && !m_axis_tready;
            held_payload={dut.output_saturated,m_axis_tdata};
            if (s_axis_tvalid && s_axis_tready) begin
                if (inputs>=count) $fatal(1,"Too many accepted inputs");
                if (first_input<0) first_input=$time/10;
                $fdisplay(input_file,"%0d %0d",inputs,$signed(s_axis_tdata));
                inputs=inputs+1;
            end
        end else held=0;
    end

    task automatic write_register(input logic [7:0] address,input logic [31:0] value);
        bit aw_done,w_done;
        integer timeout;
        @(negedge clk);
        s_axi_awaddr=address; s_axi_wdata=value; s_axi_wstrb=4'hf;
        s_axi_awvalid=1; s_axi_wvalid=1; s_axi_bready=1;
        aw_done=0; w_done=0; timeout=0;
        while (!aw_done || !w_done) begin
            @(posedge clk);
            if (s_axi_awvalid && s_axi_awready) aw_done=1;
            if (s_axi_wvalid && s_axi_wready) w_done=1;
            @(negedge clk);
            if (aw_done) s_axi_awvalid=0;
            if (w_done) s_axi_wvalid=0;
            timeout++;
            if(timeout>100) $fatal(1,"AXI write address/data timeout");
        end
        while (!s_axi_bvalid) begin
            @(negedge clk); timeout++;
            if(timeout>100) $fatal(1,"AXI write response timeout");
        end
        if(s_axi_bresp!==2'b00) $fatal(1,"AXI write rejected address=%h",address);
        @(posedge clk); @(negedge clk); s_axi_bready=0;
    endtask

    task automatic read_register(input logic [7:0] address,input logic [31:0] expected);
        integer timeout;
        @(negedge clk); s_axi_araddr=address; s_axi_arvalid=1; s_axi_rready=0;
        timeout=0;
        do begin
            @(posedge clk); timeout++;
            if(timeout>100) $fatal(1,"AXI read address timeout");
        end while (!s_axi_arready);
        @(negedge clk); s_axi_arvalid=0; s_axi_rready=1;
        while(!s_axi_rvalid) begin
            @(negedge clk); timeout++;
            if(timeout>100) $fatal(1,"AXI read response timeout");
        end
        if(s_axi_rresp!==0 || s_axi_rdata!==expected)
            $fatal(1,"AXI read mismatch address=%h got=%h expected=%h",address,s_axi_rdata,expected);
        @(posedge clk); @(negedge clk); s_axi_rready=0;
    endtask

    initial begin
        if (!$value$plusargs("COUNT=%d",count) || count<1 || count>10000)
            $fatal(1,"COUNT must be in [1,10000]");
        $readmemh("coefficients.mem",coefficient_words,0,7);
        $readmemh("input.mem",input_words,0,count-1);
        input_file=$fopen("rtl_inputs.txt","w");
        output_file=$fopen("rtl_outputs.txt","w");
        summary_file=$fopen("rtl_summary.txt","w");
        if(!input_file || !output_file || !summary_file) $fatal(1,"Cannot open job output files");
        repeat(4) @(posedge clk);
        @(negedge clk); resetn=1;
        read_register(0,0); read_register(4,1);
        for(int k=0;k<8;k++) begin
            write_register(8'h20+4*k,{{16{coefficient_words[k][15]}},coefficient_words[k]});
            read_register(8'h20+4*k,{{16{coefficient_words[k][15]}},coefficient_words[k]});
        end
        write_register(0,2); // disabled+idle soft clear, preserving coefficients
        read_register(8,0); read_register(12,0); read_register(4,1);
        write_register(0,1); read_register(0,1);
        fork
            begin : source
                for(int k=0;k<count;k++) begin
                    @(negedge clk);
                    if(k%7==0) repeat(2) @(negedge clk);
                    s_axis_tdata=input_words[k]; s_axis_tvalid=1;
                    do @(posedge clk); while(!s_axis_tready);
                    @(negedge clk); s_axis_tvalid=0;
                end
            end
            begin : sink
                while(outputs<count) begin
                    @(negedge clk); m_axis_tready=(cycles%97>=48);
                    @(posedge clk);
                    if(m_axis_tvalid && m_axis_tready) begin
                        if($isunknown({m_axis_tdata,dut.output_saturated})) $fatal(1,"Unknown output payload");
                        $fdisplay(output_file,"%0d %0d %0d",outputs,$signed(m_axis_tdata),dut.output_saturated);
                        clipped=clipped | dut.output_saturated;
                        outputs++; last_output=$time/10;
                    end
                end
                @(negedge clk); m_axis_tready=0;
            end
        join
        @(negedge clk); m_axis_tready=1;
        repeat(8) begin
            @(posedge clk);
            if(m_axis_tvalid) $fatal(1,"Unexpected output after requested data drained");
        end
        write_register(0,0);
        read_register(0,0); read_register(4,clipped ? 5 : 1);
        read_register(8,count); read_register(12,count);
        if(inputs!=count || outputs!=count || first_input<0 || last_output<first_input)
            $fatal(1,"Request transfer accounting failed");
        $fdisplay(summary_file,"%0d %0d %0d",inputs,outputs,last_output-first_input+1);
        $fclose(input_file); $fclose(output_file); $fclose(summary_file);
        $display("PASS: web_request inputs=%0d outputs=%0d rtl_cycles=%0d",inputs,outputs,last_output-first_input+1);
        $finish;
    end
endmodule
