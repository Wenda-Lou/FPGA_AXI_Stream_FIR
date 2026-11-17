"""Loopback HTTP adapter. Python standard library only."""

import argparse
import json
import logging
import os
import time
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from .service import ApiError, Service, identifier, result_csv

STATIC = Path(__file__).resolve().parent / "static"


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(2)

    def do_GET(self): self.dispatch()
    def do_POST(self): self.dispatch()
    def do_PUT(self): self.dispatch()
    def do_DELETE(self): self.dispatch()
    def do_PATCH(self): self.dispatch()
    def do_OPTIONS(self): self.dispatch()

    def log_message(self, pattern, *args):
        logging.info("request=%s HTTP %s", getattr(self, "request_id", "unassigned"), pattern % args)

    def respond(self, status, value, headers=None, content_type="application/json; charset=utf-8"):
        data = value if isinstance(value, bytes) else json.dumps(value, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Request-ID", self.request_id)
        for name, value in (headers or {}).items(): self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        if self.headers.get("Transfer-Encoding") is not None:
            raise ApiError(400, "INVALID_REQUEST", "Transfer encoding is not supported.")
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) != 1 or not lengths[0].isdigit():
            raise ApiError(400, "INVALID_REQUEST", "A single Content-Length is required.")
        length = int(lengths[0])
        if length > 2*1024*1024:
            # Drain with a bounded deadline so Windows does not reset the socket
            # with unread upload bytes before the client receives its 413.
            self.connection.settimeout(.5)
            remaining, deadline = length, time.monotonic()+2
            while remaining and time.monotonic() < deadline:
                try: chunk = self.rfile.read(min(65536, remaining))
                except (TimeoutError, ConnectionError): break
                if not chunk: break
                remaining -= len(chunk)
            raise ApiError(413, "UPLOAD_TOO_LARGE", "Request exceeds 2 MiB.")
        self.connection.settimeout(10)
        body = self.rfile.read(length)
        if len(body) != length: raise ApiError(400, "INVALID_REQUEST", "Incomplete request body.")
        return body

    def dispatch(self):
        self.request_id = identifier("req")
        service = self.server.service
        path = urlsplit(self.path).path
        parts = path.strip("/").split("/")
        try:
            if self.command == "GET" and path in ("/", "/app.js", "/style.css"):
                filename, content_type = {"/": ("index.html", "text/html; charset=utf-8"),
                                          "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                                          "/style.css": ("style.css", "text/css; charset=utf-8")}[path]
                if not (STATIC / filename).is_file(): raise ApiError(404, "NOT_FOUND", "Page not implemented.")
                return self.respond(200, (STATIC / filename).read_bytes(), content_type=content_type)
            if self.command == "GET" and path == "/api/v1/capabilities":
                return self.respond(200, service.capabilities())
            if self.command == "POST" and path == "/api/v1/datasets":
                content_type = self.headers.get("Content-Type", "")
                if content_type.split(";")[0].lower() != "multipart/form-data":
                    raise ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "Expected multipart/form-data.")
                body = self.body()
                message = BytesParser(policy=policy.default).parsebytes(
                    b"Content-Type: " + content_type.encode("ascii") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body)
                items = list(message.iter_parts()) if message.is_multipart() else []
                if message.defects or len(items) != 1 or items[0].is_multipart() or items[0].defects or \
                    items[0].get_content_disposition() != "form-data" or items[0].get_param("name", header="content-disposition") != "file" or items[0].get_filename() is None:
                    raise ApiError(400, "INVALID_CSV", "Expected exactly one file part named file.", "file")
                data = service.upload(items[0].get_payload(decode=True))
                return self.respond(201, data, {"Location": "/api/v1/datasets/" + data["dataset_id"]})
            if self.command == "GET" and len(parts) == 4 and parts[:3] == ["api", "v1", "datasets"]:
                return self.respond(200, service.dataset(parts[3])[0])
            if self.command == "POST" and path == "/api/v1/jobs":
                if self.headers.get("Content-Type", "").split(";")[0].lower() != "application/json":
                    raise ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "Expected application/json.")
                try:
                    request = json.loads(self.body().decode("utf-8"), object_pairs_hook=strict_object,
                                         parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
                except (ValueError, UnicodeError):
                    raise ApiError(400, "INVALID_JSON", "Malformed JSON.")
                status = service.submit(request, self.request_id)
                return self.respond(202, status, {"Location": "/api/v1/jobs/" + status["job_id"]})
            if self.command == "GET" and parts[:3] == ["api", "v1", "jobs"]:
                if len(parts) == 4: return self.respond(200, service.job(parts[3])[0])
                if len(parts) == 5 and parts[4] in ("result", "result.csv"):
                    result = service.result(parts[3])
                    if parts[4] == "result.csv":
                        return self.respond(200, result_csv(result),
                                            {"Content-Disposition": f'attachment; filename="fir-{result["job_id"]}.csv"'},
                                            "text/csv; charset=utf-8")
                    return self.respond(200, result)
            raise ApiError(404, "NOT_FOUND", "Endpoint does not exist.")
        except ApiError as error:
            self.respond(error.status, {"error": error.payload(self.request_id)})
        except (TimeoutError, ConnectionError):
            self.close_connection = True
        except Exception:
            logging.exception("HTTP failure request=%s", self.request_id)
            self.respond(500, {"error": ApiError(500, "INTERNAL_ERROR", "Internal server error.").payload(self.request_id)})


class Server(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, address, service):
        if address[0] != "127.0.0.1": raise ValueError("Only loopback binding is supported")
        self.service = service
        super().__init__(address, Handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--data-dir", type=Path, default=Path("build/webapp"))
    parser.add_argument("--reference-timeout", type=float, default=30)
    parser.add_argument("--vivado-bin", type=Path, default=os.environ.get("FIR_VIVADO_BIN"))
    parser.add_argument("--rtl-timeout", type=float, default=300)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    service = Service(args.data_dir, args.reference_timeout, vivado_bin=args.vivado_bin, rtl_timeout=args.rtl_timeout)
    try:
        server = Server(("127.0.0.1", args.port), service)
        print(f"FIR console: http://127.0.0.1:{server.server_port}", flush=True)
        try: server.serve_forever()
        except KeyboardInterrupt: pass
        finally: server.server_close()
    finally:
        service.close()


if __name__ == "__main__": main()
