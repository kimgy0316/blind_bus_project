from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import webbrowser


ROOT = Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "app"
HOST = "127.0.0.1"
PORT = 8000
MAX_PORT_TRIES = 20


class AppHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(APP_DIR), **kwargs)


def main():
    if not (APP_DIR / "voice_guidance_app.html").exists():
        raise FileNotFoundError(f"앱 파일을 찾을 수 없습니다: {APP_DIR}")

    server = None
    port = PORT

    for candidate_port in range(PORT, PORT + MAX_PORT_TRIES):
        try:
            server = ThreadingHTTPServer((HOST, candidate_port), AppHandler)
            port = candidate_port
            break
        except OSError:
            continue

    if server is None:
        raise RuntimeError("사용 가능한 로컬 포트를 찾지 못했습니다.")

    url = f"http://{HOST}:{port}/voice_guidance_app.html"

    print(f"앱 실행 주소: {url}")
    print("종료하려면 Ctrl+C를 누르세요.")

    webbrowser.open(url)
    server.serve_forever()


if __name__ == "__main__":
    main()
