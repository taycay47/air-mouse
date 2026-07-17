import { useState, useEffect } from "react";
import { List, Detail, ActionPanel, Action, showToast, Toast } from "@raycast/api";
import { exec, spawn } from "child_process";
import os from "os";
import net from "net";
import path from "path";

// Paths config
const WORKSPACE_DIR = "/Users/robert/Documents/antigravity/bold-darwin";
const PYTHON_PATH = path.join(WORKSPACE_DIR, ".venv/bin/python3");
const SCRIPT_PATH = path.join(WORKSPACE_DIR, "mouse_controller.py");

interface NetworkInterface {
  name: string;
  type: string;
  address: string;
  url: string;
  qrUrl: string;
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
    url: `https://${bonjourName}:8443`,
    qrUrl: `https://api.qrserver.com/v1/create-qr-code/?size=350x350&data=${encodeURIComponent(`https://${bonjourName}:8443`)}`,
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
            url: `https://${ip}:8443`,
            qrUrl: `https://api.qrserver.com/v1/create-qr-code/?size=350x350&data=${encodeURIComponent(`https://${ip}:8443`)}`,
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
          url: `https://${wrappedIp}:8443`,
          qrUrl: `https://api.qrserver.com/v1/create-qr-code/?size=350x350&data=${encodeURIComponent(`https://${wrappedIp}:8443`)}`,
          description: "Carrier direct routing. Crucial for Personal Hotspots since carriers route IPv6 directly without translation blocks.",
        });
      }

      // 4. Local IPv4
      if (netInterface.family === "IPv4" && !ip.startsWith("127.") && !ip.startsWith("100.")) {
        list.push({
          name: `Local IPv4 (${name})`,
          type: "IPv4",
          address: ip,
          url: `https://${ip}:8443`,
          qrUrl: `https://api.qrserver.com/v1/create-qr-code/?size=350x350&data=${encodeURIComponent(`https://${ip}:8443`)}`,
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

  // Check status and update network on mount
  useEffect(() => {
    setInterfaces(getNetworkInterfaces());

    const checkStatus = () => {
      checkPort(8443).then((running) => {
        setIsRunning(running);
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
      // Sweep clean any lingering process on port 8443 first
      await new Promise<void>((resolve) => {
        exec("lsof -t -i:8443 | xargs kill -9", () => resolve());
      });
      await new Promise((r) => setTimeout(r, 200));

      // Spawn server process as detached daemon so it survives Raycast window closing
      const child = spawn(PYTHON_PATH, [SCRIPT_PATH], {
        detached: true,
        stdio: "ignore",
        cwd: WORKSPACE_DIR,
      });
      child.unref();

      // Poll the port status for up to 3 seconds to wait for Python to boot
      let isOpened = false;
      for (let i = 0; i < 15; i++) {
        await new Promise((r) => setTimeout(r, 200));
        const running = await checkPort(8443);
        if (running) {
          isOpened = true;
          break;
        }
      }

      if (isOpened) {
        setIsRunning(true);
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

    // Kill any python process using port 8443 or 8444
    exec("lsof -t -i:8443 -i:8444 | xargs kill -9", async (err) => {
      await new Promise((r) => setTimeout(r, 500));
      setIsRunning(false);
      toast.title = "Server stopped";
      toast.style = Toast.Style.Success;
    });
  };

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
        const md = `
# 🖱️ Connection Channel: ${item.name}

Scan this QR code with your iPhone to pair using this interface:

![Pairing QR Code](${item.qrUrl})

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
