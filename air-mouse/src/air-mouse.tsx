import { useState, useEffect } from "react";
import { List, Detail, ActionPanel, Action, showToast, Toast, getPreferenceValues, environment } from "@raycast/api";
import { exec, spawn } from "child_process";
import fs from "fs";
import os from "os";
import net from "net";
import path from "path";
import QRCode from "qrcode";

interface Preferences {
  workspaceDir?: string;
}

// Resolve the folder containing mouse_controller.py. Prefers the user-set
// preference (needed once this extension is installed separately from the
// server); otherwise walks up from this file's own location looking for a
// sibling mouse_controller.py, which works for local/dev use where this
// extension lives inside the same repo checkout.
function findWorkspaceDir(): string {
  const prefs = getPreferenceValues<Preferences>();
  if (prefs.workspaceDir && fs.existsSync(path.join(prefs.workspaceDir, "mouse_controller.py"))) {
    return prefs.workspaceDir;
  }

  let dir = __dirname;
  for (let i = 0; i < 8; i++) {
    if (fs.existsSync(path.join(dir, "mouse_controller.py"))) {
      return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }

  throw new Error(
    "Could not find mouse_controller.py. Set the 'Air Mouse Server Directory' preference to the folder that contains it.",
  );
}

const SERVER_LOG_PATH = path.join(environment.supportPath, "server.log");
const SERVER_PORT = 8443;

interface NetworkInterface {
  name: string;
  type: string;
  address: string;
  url: string;
  description: string;
}

// Check if port is in use (server running) by attempting a connection
function checkPort(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const client = net.createConnection({ port, host: "127.0.0.1", timeout: 150 }, () => {
      client.end();
      resolve(true); // Connected successfully => server is running
    });
    client.on("error", () => {
      // If IPv4 loopback fails, check IPv6 loopback
      const client6 = net.createConnection({ port, host: "::1", timeout: 150 }, () => {
        client6.end();
        resolve(true);
      });
      client6.on("error", () => {
        resolve(false); // Both failed => server is stopped
      });
    });
  });
}

// Kill only *our* server process, matched by its command line rather than by
// whatever happens to be bound to the port — a stray unrelated process on
// 8443 is left alone.
function killServerProcesses(): Promise<void> {
  return new Promise((resolve) => {
    exec("pgrep -f 'mouse_controller.py'", (_err, stdout) => {
      const pids = stdout
        .split("\n")
        .map((s) => s.trim())
        .filter(Boolean);
      if (pids.length === 0) {
        resolve();
        return;
      }
      exec(`kill -9 ${pids.join(" ")}`, () => resolve());
    });
  });
}

// Read the current pairing PIN out of the server's own log output.
function readPairingPin(): string | null {
  try {
    const contents = fs.readFileSync(SERVER_LOG_PATH, "utf-8");
    const match = contents.match(/PAIRING PIN:\s*(\d{4,6})/);
    return match ? match[1] : null;
  } catch {
    return null;
  }
}

// Build list of active IP configurations
function getNetworkInterfaces(): NetworkInterface[] {
  const list: NetworkInterface[] = [];

  // 1. Add Bonjour Hostname
  const host = os.hostname();
  const bonjourName = host.endsWith(".local") ? host : `${host}.local`;
  list.push({
    name: "Bonjour (mDNS)",
    type: "Bonjour",
    address: bonjourName,
    url: `https://${bonjourName}:${SERVER_PORT}`,
    description: "Standard local hostname resolution. Highly stable on home and office Wi-Fi routers.",
  });

  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    const netList = interfaces[name];
    if (!netList) continue;

    for (const netInterface of netList) {
      if (netInterface.internal) continue;

      const ip = netInterface.address;

      // 2. Tailscale (VPN)
      if (netInterface.family === "IPv4" && ip.startsWith("100.")) {
        const parts = ip.split(".").map(Number);
        if (parts[1] >= 64 && parts[1] < 128) {
          list.push({
            name: "Tailscale VPN",
            type: "Tailscale",
            address: ip,
            url: `https://${ip}:${SERVER_PORT}`,
            description: "Direct secure connection over the Tailscale VPN. Requires Tailscale running on both devices.",
          });
        }
      }

      // 3. Global IPv6
      if (netInterface.family === "IPv6" && !ip.startsWith("fe80") && !ip.startsWith("::1")) {
        const wrappedIp = `[${ip}]`;
        list.push({
          name: "Global IPv6",
          type: "IPv6",
          address: ip,
          url: `https://${wrappedIp}:${SERVER_PORT}`,
          description:
            "Carrier direct routing. Crucial for Personal Hotspots since carriers route IPv6 directly without translation blocks.",
        });
      }

      // 4. Local IPv4
      if (netInterface.family === "IPv4" && !ip.startsWith("127.") && !ip.startsWith("100.")) {
        list.push({
          name: `Local IPv4 (${name})`,
          type: "IPv4",
          address: ip,
          url: `https://${ip}:${SERVER_PORT}`,
          description: "Standard local IPv4 address. Standard for routers, though cellular hotspots often isolate client IPs.",
        });
      }
    }
  }

  return list;
}

export default function Command() {
  const [isRunning, setIsRunning] = useState<boolean | null>(null);
  const [interfaces, setInterfaces] = useState<NetworkInterface[]>([]);
  const [qrMap, setQrMap] = useState<Record<string, string>>({});
  const [pin, setPin] = useState<string | null>(null);
  const [setupError, setSetupError] = useState<string | null>(null);

  let workspaceDir = "";
  let pythonPath = "";
  let scriptPath = "";
  if (!setupError) {
    try {
      workspaceDir = findWorkspaceDir();
      pythonPath = path.join(workspaceDir, ".venv/bin/python3");
      scriptPath = path.join(workspaceDir, "mouse_controller.py");
    } catch (err) {
      if (!setupError) setSetupError(String(err));
    }
  }

  // Check status and update network + QR codes on mount
  useEffect(() => {
    const list = getNetworkInterfaces();
    setInterfaces(list);

    (async () => {
      const entries = await Promise.all(
        list.map(async (item) => {
          try {
            const dataUrl = await QRCode.toDataURL(item.url, { margin: 1, width: 320 });
            return [item.url, dataUrl] as const;
          } catch {
            return [item.url, ""] as const;
          }
        }),
      );
      setQrMap(Object.fromEntries(entries));
    })();

    const checkStatus = () => {
      checkPort(SERVER_PORT).then((running) => {
        setIsRunning(running);
        setPin(running ? readPairingPin() : null);
      });
    };

    checkStatus();
    const interval = setInterval(checkStatus, 1500);
    return () => clearInterval(interval);
  }, []);

  const handleStart = async () => {
    const toast = await showToast({
      title: "Starting server...",
      style: Toast.Style.Animated,
    });

    try {
      // Sweep clean any lingering instance of our own server first
      await killServerProcesses();
      await new Promise((r) => setTimeout(r, 200));

      fs.mkdirSync(environment.supportPath, { recursive: true });
      const logFd = fs.openSync(SERVER_LOG_PATH, "w");

      // Spawn server process as detached daemon so it survives Raycast window closing.
      // stdout/stderr go to a log file (not a pipe) so the server never blocks on
      // writes once Raycast stops reading — the extension polls the file instead.
      const child = spawn(pythonPath, [scriptPath], {
        detached: true,
        stdio: ["ignore", logFd, logFd],
        cwd: workspaceDir,
      });
      child.unref();
      fs.closeSync(logFd);

      // Poll the port status for up to 3 seconds to wait for Python to boot
      let isOpened = false;
      for (let i = 0; i < 15; i++) {
        await new Promise((r) => setTimeout(r, 200));
        const running = await checkPort(SERVER_PORT);
        if (running) {
          isOpened = true;
          break;
        }
      }

      if (isOpened) {
        setIsRunning(true);
        setPin(readPairingPin());
        toast.title = "Server is active!";
        toast.style = Toast.Style.Success;
      } else {
        throw new Error("Failed to bind port (timeout)");
      }
    } catch (err) {
      toast.title = "Error starting server";
      toast.style = Toast.Style.Failure;
      toast.message = String(err);
    }
  };

  const handleStop = async () => {
    const toast = await showToast({
      title: "Stopping server...",
      style: Toast.Style.Animated,
    });

    await killServerProcesses();
    await new Promise((r) => setTimeout(r, 500));
    setIsRunning(false);
    setPin(null);
    toast.title = "Server stopped";
    toast.style = Toast.Style.Success;
  };

  if (setupError) {
    return (
      <Detail
        markdown={`# ⚠️ Setup Needed\n\n${setupError}\n\nOpen this extension's preferences (\`Cmd + Shift + ,\`) and set **Air Mouse Server Directory**.`}
      />
    );
  }

  if (isRunning === null) {
    return <List isLoading={true} />;
  }

  if (!isRunning) {
    return (
      <Detail
        markdown={`
# 🖱️ Mac Remote Controller

The background server is currently **stopped**.

Start the server using the action panel (\`Cmd + Enter\`) to display the pairing QR codes.
`}
        actions={
          <ActionPanel>
            <Action title="Start Server" onAction={handleStart} />
          </ActionPanel>
        }
      />
    );
  }

  return (
    <List isShowingDetail searchBarPlaceholder="Search connection type...">
      {interfaces.map((item, index) => {
        const qr = qrMap[item.url];
        const md = `
# 🖱️ Connection Channel: ${item.name}

${pin ? `### Pairing PIN: \`${pin}\`\nEnter this on the phone the first time it connects.\n\n` : ""}Scan this QR code with your iPhone to pair using this interface:

${qr ? `![Pairing QR Code](${qr})` : "_Generating QR code..._"}

**Direct Link:** [${item.url}](${item.url})

---

### Channel Info
${item.description}

### ⚠️ One-Time Setup in Safari
Because we use a self-signed SSL certificate:
1. Open the camera, tap the link to load in Safari.
2. Tap **Show Details** at the bottom of the private connection warning page.
3. Tap **"visit this website"** to grant permission.
4. Allow motion/orientation access when prompted.
`;
        return (
          <List.Item
            key={index}
            title={item.name}
            subtitle={item.address}
            detail={<List.Item.Detail markdown={md} />}
            actions={
              <ActionPanel>
                <Action.CopyToClipboard title="Copy Connection URL" content={item.url} />
                {pin && <Action.CopyToClipboard title="Copy Pairing PIN" content={pin} />}
                <Action.OpenInBrowser title="Open Connection Locally" url={item.url} />
                <Action title="Stop Server" onAction={handleStop} style={Action.Style.Destructive} />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
