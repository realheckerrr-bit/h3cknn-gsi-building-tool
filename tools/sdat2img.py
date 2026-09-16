#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ==============================================================================
# sdat2img.py - Convert system.new.dat to ext4 raw image
# ==============================================================================

import sys
import os

def parse_transfer_list(transfer_list_file):
    commands = []
    with open(transfer_list_file, 'r') as f:
        version = int(f.readline().strip())
        total_blocks = int(f.readline().strip())
        if version >= 2:
            f.readline()  # stash entries
            f.readline()  # max stash
        for line in f:
            parts = line.strip().split()
            if not parts:
                continue
            cmd = parts[0]
            if cmd in ('new', 'zero', 'erase'):
                commands.append((cmd, [int(x) for x in parts[1:]]))
    return version, total_blocks, commands

def ranges_to_blocks(ranges):
    blocks = []
    num_ranges = ranges[0]
    for i in range(1, num_ranges * 2, 2):
        start = ranges[i]
        end = ranges[i + 1]
        blocks.extend(range(start, end))
    return blocks

def main():
    if len(sys.argv) < 4:
        print("Usage: sdat2img.py <transfer_list> <system_new_dat> <output_image>")
        sys.exit(1)

    transfer_list_path = sys.argv[1]
    new_dat_path = sys.argv[2]
    output_img_path = sys.argv[3]

    BLOCK_SIZE = 4096

    version, total_blocks, commands = parse_transfer_list(transfer_list_path)
    print(f"[*] Android Transfer List Version: {version}, Total blocks: {total_blocks}")

    with open(new_dat_path, 'rb') as new_dat, open(output_img_path, 'wb') as out_img:
        for cmd, ranges in commands:
            blocks = ranges_to_blocks(ranges)
            if cmd == 'new':
                for block in blocks:
                    data = new_dat.read(BLOCK_SIZE)
                    if len(data) < BLOCK_SIZE:
                        data += b'\0' * (BLOCK_SIZE - len(data))
                    out_img.seek(block * BLOCK_SIZE)
                    out_img.write(data)
            elif cmd == 'zero':
                for block in blocks:
                    out_img.seek(block * BLOCK_SIZE)
                    out_img.write(b'\0' * BLOCK_SIZE)

    print(f"[+] Successfully converted to raw image: {output_img_path}")

if __name__ == '__main__':
    main()
