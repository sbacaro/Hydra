#!/usr/bin/env python3
"""
Create a GitHub release for Hydra Audio with asset upload.
Requires: GITHUB_TOKEN environment variable set to a valid GitHub personal access token.
"""

import os
import sys
import json
import subprocess
from pathlib import Path

def run_cmd(cmd):
    """Run a shell command and return output."""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.stdout.strip(), result.stderr.strip(), result.returncode

def main():
    # Configuration
    repo = "sbacaro/Hydra"
    tag = "v0.15.1-beta"
    release_name = "Hydra Audio 0.15.1 beta"
    
    # Get GitHub token
    token = os.getenv("GITHUB_TOKEN")
    if not token:
        print("❌ Error: GITHUB_TOKEN environment variable not set")
        print("   Create a token at: https://github.com/settings/tokens")
        print("   Required scopes: repo (full control)")
        sys.exit(1)
    
    # Read release notes
    notes_file = Path(__file__).parent / "RELEASE_NOTES_0.15.1.md"
    if not notes_file.exists():
        print(f"❌ Error: {notes_file} not found")
        sys.exit(1)
    
    with open(notes_file) as f:
        body = f.read()
    
    # Prepare release data
    release_data = {
        "tag_name": tag,
        "name": release_name,
        "body": body,
        "draft": False,
        "prerelease": True  # Mark as beta
    }
    
    # Create release via GitHub API
    print(f"📦 Creating release: {release_name}")
    print(f"   Tag: {tag}")
    print(f"   Repo: {repo}")
    
    api_url = f"https://api.github.com/repos/{repo}/releases"
    
    cmd = f"""curl -X POST \\
  -H "Authorization: token {token}" \\
  -H "Content-Type: application/json" \\
  -d '{json.dumps(release_data)}' \\
  {api_url}"""
    
    stdout, stderr, code = run_cmd(cmd)
    
    if code != 0:
        print(f"❌ Failed to create release: {stderr}")
        sys.exit(1)
    
    try:
        response = json.loads(stdout)
        if "id" not in response:
            print(f"❌ Unexpected response: {response}")
            sys.exit(1)
        
        release_id = response["id"]
        upload_url = response["upload_url"].replace("{?name,label}", "")
        
        print(f"✓ Release created (ID: {release_id})")
        print(f"  Upload URL: {upload_url}")
        
    except json.JSONDecodeError as e:
        print(f"❌ Failed to parse response: {e}")
        print(f"   Response: {stdout}")
        sys.exit(1)
    
    # Upload asset
    asset_file = Path(__file__).parent / "Hydra-0.15.1-beta.zip"
    if not asset_file.exists():
        print(f"⚠️  Asset not found: {asset_file}")
        print(f"   Skipping asset upload")
        print(f"\n✓ Release created successfully!")
        print(f"   https://github.com/{repo}/releases/tag/{tag}")
        return
    
    print(f"\n📤 Uploading asset: {asset_file.name}")
    file_size = asset_file.stat().st_size / (1024 * 1024)
    print(f"   Size: {file_size:.1f} MB")
    
    upload_cmd = f"""curl -X POST \\
  -H "Authorization: token {token}" \\
  -H "Content-Type: application/zip" \\
  --data-binary @{asset_file} \\
  "{upload_url}?name={asset_file.name}" """
    
    stdout, stderr, code = run_cmd(upload_cmd)
    
    if code != 0:
        print(f"⚠️  Asset upload failed: {stderr}")
    else:
        try:
            asset_response = json.loads(stdout)
            if "id" in asset_response:
                print(f"✓ Asset uploaded successfully")
                print(f"  Download: {asset_response['browser_download_url']}")
        except json.JSONDecodeError:
            print(f"⚠️  Could not parse asset response")
    
    print(f"\n✅ Release complete!")
    print(f"   View at: https://github.com/{repo}/releases/tag/{tag}")

if __name__ == "__main__":
    main()
