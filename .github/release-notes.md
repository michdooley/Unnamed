## Install

1. Download **Unnamed-x.y.z.dmg** below, open it, and drag **Unnamed** into **Applications**.
2. Open Unnamed. Because it isn't notarized by Apple (that needs a paid developer account), macOS says it can't check it for malicious software. Click **Done**.
3. Open **System Settings › Privacy & Security**, scroll down to “Unnamed was blocked…”, click **Open Anyway**, and confirm. You only do this once per download.

Prefer Terminal? `xattr -dr com.apple.quarantine /Applications/Unnamed.app` does the same.

Unnamed is open source: you can read every line, or build it yourself with Xcode. Requires macOS 15 or later, on Apple silicon or Intel. Updating to a new version? The first time you open it, it may ask you to point it at your library folder again.

`SHA256SUMS.txt` lists the files' checksums.
