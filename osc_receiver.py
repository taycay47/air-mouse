#!/usr/bin/env python3
import socket
import struct
import sys

def parse_osc_message(data):
    if not data.startswith(b'/'):
        return None, None
    
    addr_end = data.find(b'\x00')
    if addr_end == -1:
        return None, None
    address = data[:addr_end].decode('utf-8', errors='replace')
    
    tag_start = ((addr_end // 4) + 1) * 4
    if tag_start >= len(data):
        return address, []
    
    if data[tag_start:tag_start+1] != b',':
        return address, []
        
    tag_end = data.find(b'\x00', tag_start)
    if tag_end == -1:
        return address, []
    type_tags = data[tag_start+1:tag_end].decode('utf-8', errors='replace')
    
    arg_start = ((tag_end // 4) + 1) * 4
    args = []
    
    for tag in type_tags:
        if arg_start >= len(data):
            break
        if tag == 'f':
            if arg_start + 4 > len(data):
                break
            val = struct.unpack('>f', data[arg_start:arg_start+4])[0]
            args.append(val)
            arg_start += 4
        elif tag == 'i':
            if arg_start + 4 > len(data):
                break
            val = struct.unpack('>i', data[arg_start:arg_start+4])[0]
            args.append(val)
            arg_start += 4
        elif tag == 's':
            str_end = data.find(b'\x00', arg_start)
            if str_end == -1:
                val = data[arg_start:].decode('utf-8', errors='replace')
                args.append(val)
                break
            val = data[arg_start:str_end].decode('utf-8', errors='replace')
            args.append(val)
            arg_start = ((str_end // 4) + 1) * 4
        else:
            # Skip unknown tags
            arg_start += 4
            
    return address, args

def parse_packet(data):
    if data.startswith(b'#bundle\x00'):
        if len(data) < 16:
            return []
        idx = 16
        messages = []
        while idx < len(data):
            if idx + 4 > len(data):
                break
            size = struct.unpack('>i', data[idx:idx+4])[0]
            idx += 4
            if idx + size > len(data):
                break
            element_data = data[idx:idx+size]
            messages.extend(parse_packet(element_data))
            idx += size
        return messages
    else:
        addr, args = parse_osc_message(data)
        if addr:
            return [(addr, args)]
        return []

def main():
    port = 8000
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            print(f"Invalid port number. Using default: {port}")
        
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    
    # Allow address reuse
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    
    # Enable dual-stack (allow both IPv4 and IPv6 connections)
    try:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    except Exception:
        pass
        
    try:
        sock.bind(('::', port))
    except Exception as e:
        print(f"Error binding to port {port}: {e}")
        print("Maybe another process is using it? You can specify a different port: python3 osc_receiver.py [port]")
        return
        
    print(f"==========================================================")
    print(f" OSC Telemetry Receiver Listening on UDP port {port}...")
    print(f" Configure your iPhone Data OSC app target to this Mac's IP")
    print(f" Port: {port}")
    print(f"==========================================================")
    print("Press Ctrl+C to exit.\n")
    
    try:
        while True:
            data, addr = sock.recvfrom(65535)
            msgs = parse_packet(data)
            for path, args in msgs:
                # Format arguments nicely for printing
                args_str = ", ".join(f"{v:.4f}" if isinstance(v, float) else str(v) for v in args)
                print(f"[{addr[0]}:{addr[1]}] {path} -> [{args_str}]")
    except KeyboardInterrupt:
        print("\nStopping receiver.")
    finally:
        sock.close()

if __name__ == "__main__":
    main()
