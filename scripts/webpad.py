"""A virtual Xbox 360 controller driven from a web page - for testing the
controller UI without a controller.

    tools\\pyenv\\Scripts\\python scripts\\webpad.py

Then open the address it prints on a phone (same Wi-Fi) and tap the buttons.
The PC's keyboard and mouse are not involved, so the game stays in controller
mode. Needs the ViGEmBus driver and `pip install vgamepad`.
"""
import http.server
import socket
import sys

import vgamepad as vg

PORT = 8777
B = vg.XUSB_BUTTON
BUTTONS = {
    "A": B.XUSB_GAMEPAD_A, "B": B.XUSB_GAMEPAD_B, "X": B.XUSB_GAMEPAD_X, "Y": B.XUSB_GAMEPAD_Y,
    "LB": B.XUSB_GAMEPAD_LEFT_SHOULDER, "RB": B.XUSB_GAMEPAD_RIGHT_SHOULDER,
    "L3": B.XUSB_GAMEPAD_LEFT_THUMB, "R3": B.XUSB_GAMEPAD_RIGHT_THUMB,
    "START": B.XUSB_GAMEPAD_START, "BACK": B.XUSB_GAMEPAD_BACK,
    "UP": B.XUSB_GAMEPAD_DPAD_UP, "DOWN": B.XUSB_GAMEPAD_DPAD_DOWN,
    "LEFT": B.XUSB_GAMEPAD_DPAD_LEFT, "RIGHT": B.XUSB_GAMEPAD_DPAD_RIGHT,
}
# Left stick (LS*) and right stick (RS*) directions, as (x, y).
STICKS = {
    "LSU": ("L", 0, 1), "LSD": ("L", 0, -1), "LSL": ("L", -1, 0), "LSR": ("L", 1, 0),
    "RSU": ("R", 0, 1), "RSD": ("R", 0, -1), "RSL": ("R", -1, 0), "RSR": ("R", 1, 0),
}
TRIGGERS = {"LT", "RT"}

pad = vg.VX360Gamepad()
held = set()


def apply():
    for stick, setter in (("L", pad.left_joystick_float), ("R", pad.right_joystick_float)):
        x = sum(dx for name, (s, dx, _) in STICKS.items() if s == stick and name in held)
        y = sum(dy for name, (s, _, dy) in STICKS.items() if s == stick and name in held)
        setter(x_value_float=float(max(-1, min(1, x))), y_value_float=float(max(-1, min(1, y))))
    pad.left_trigger_float(value_float=1.0 if "LT" in held else 0.0)
    pad.right_trigger_float(value_float=1.0 if "RT" in held else 0.0)
    pad.update()


def set_button(name, down):
    if name in BUTTONS:
        (pad.press_button if down else pad.release_button)(button=BUTTONS[name])
    elif name in STICKS or name in TRIGGERS:
        (held.add if down else held.discard)(name)
    else:
        return False
    apply()
    return True


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
<title>Virtual pad</title>
<style>
  body { margin: 0; background: #16161a; color: #ddd; font: 16px system-ui, sans-serif;
         -webkit-user-select: none; user-select: none; touch-action: none; }
  h2 { font-size: 13px; font-weight: 600; margin: 14px 12px 6px; color: #999; }
  .grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; padding: 0 10px; }
  button { height: 62px; border: 1px solid #3a3a44; border-radius: 10px; background: #26262e;
           color: #eee; font: 600 17px system-ui, sans-serif; touch-action: none; }
  button.on { background: #5a7cff; border-color: #8aa2ff; }
  .empty { visibility: hidden; }
</style></head><body>
<h2>Bumpers / triggers / menu</h2>
<div class="grid">
  <button data-b="LT">LT</button><button data-b="LB">LB</button><button data-b="RB">RB</button><button data-b="RT">RT</button>
  <button data-b="BACK">Back</button><button data-b="START">Start</button><button data-b="L3">L3</button><button data-b="R3">R3</button>
</div>
<h2>D-pad &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Face buttons</h2>
<div class="grid">
  <button class="empty"></button><button data-b="UP">&#9650;</button><button class="empty"></button><button data-b="Y">Y</button>
  <button data-b="LEFT">&#9664;</button><button data-b="DOWN">&#9660;</button><button data-b="RIGHT">&#9654;</button><button data-b="X">X</button>
  <button class="empty"></button><button class="empty"></button><button data-b="A">A</button><button data-b="B">B</button>
</div>
<h2>Left stick &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; Right stick</h2>
<div class="grid">
  <button data-b="LSU">L&#9650;</button><button data-b="LSD">L&#9660;</button><button data-b="RSU">R&#9650;</button><button data-b="RSD">R&#9660;</button>
  <button data-b="LSL">L&#9664;</button><button data-b="LSR">L&#9654;</button><button data-b="RSL">R&#9664;</button><button data-b="RSR">R&#9654;</button>
</div>
<h2>Same PC as the game? Press with a delay, then click the game window</h2>
<div class="grid">
  <button id="delay" style="grid-column: span 4">Delay: off</button>
</div>
<script>
  const send = (name, down) => fetch('/' + (down ? 'd' : 'u') + '/' + name, { method: 'POST' });
  // With the delay on, a tap is sent 4 seconds later and held briefly, which
  // leaves time to give the focus back to the game.
  let delayed = false;
  const delayButton = document.getElementById('delay');
  delayButton.addEventListener('click', () => {
    delayed = !delayed;
    delayButton.textContent = 'Delay: ' + (delayed ? '4 s' : 'off');
    delayButton.classList.toggle('on', delayed);
  });
  for (const el of document.querySelectorAll('button[data-b]')) {
    const name = el.dataset.b;
    const down = e => {
      e.preventDefault();
      el.classList.add('on');
      if (!delayed) { send(name, true); return; }
      setTimeout(() => {
        send(name, true);
        setTimeout(() => { send(name, false); el.classList.remove('on'); }, 250);
      }, 4000);
    };
    const up = e => { e.preventDefault(); if (delayed) return; el.classList.remove('on'); send(name, false); };
    el.addEventListener('pointerdown', down);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', up);
    el.addEventListener('pointerleave', e => { if (el.classList.contains('on')) up(e); });
  }
</script></body></html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        ok = len(parts) == 2 and parts[0] in ("d", "u") and set_button(parts[1].upper(), parts[0] == "d")
        self.send_response(204 if ok else 400)
        self.end_headers()

    def log_message(self, *args):
        pass


def lan_addresses():
    try:
        return sorted({a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)})
    except OSError:
        return []


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("Virtual controller is connected. Open one of these on your phone:")
    for ip in lan_addresses():
        print(f"    http://{ip}:{PORT}")
    print("Ctrl+C to stop (the controller disconnects).")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
