#!/usr/bin/env python3
"""
Upload Hydra .pkg to existing GitHub release
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
    pkg_file = "Hydra-0.15.1.pkg"
    
    # Get GitHub token
    token = os.getenv("GITHUB_TOKEN")
    if not token:
        print("❌ Error: GITHUB_TOKEN environment variable not set")
        print("   Run: export GITHUB_TOKEN=\"ghp_your_token_here\"")
        sys.exit(1)
    
    # Check if .pkg file exists
    pkg_path = Path(__file__).parent / pkg_file
    if not pkg_path.exists():
        print(f"❌ Error: {pkg_file} not found")
        print("   Run ./build_pkg.sh first")
        sys.exit(1)
    
    file_size = pkg_path.stat().st_size / (1024 * 1024)
    print(f"📦 Uploading {pkg_file} to release")
    print(f"   Size: {file_size:.1f} MB")
    print(f"   Tag: {tag}")
    print(f"   Repo: {repo}")
    
    # Get release info
    api_url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    
    cmd = f"""curl -s \\
  -H "Authorization: token {token}" \\
  -H "Accept: application/vnd.github.v3+json" \\
  "{api_url}" """
    
    stdout, stderr, code = run_cmd(cmd)
    
    if code != 0:
        print(f"❌ Failed to get release info: {stderr}")
        sys.exit(1)
    
    try:
        response = json.loads(stdout)
        if "id" not in response:
            print(f"❌ Release not found: {response}")
            sys.exit(1)
        
        release_id = response["id"]
        upload_url = response["upload_url"].replace("{?name,label}", "")
        
        print(f"✓ Found release ID: {release_id}")
        
        # Check if .pkg already exists
        existing_assets = response.get("assets", [])
        for asset in existing_assets:
            if asset["name"] == pkg_file:
                print(f"⚠️  {pkg_file} already exists in release")
                print(f"   ID: {asset['id']}")
                
                # Ask user if they want to replace
                response = input("Replace existing .pkg? (y/N): ")
                if response.lower() != 'y':
                    print("Upload cancelled")
                    return
                
                print("Deleting old .pkg...")
                delete_url = f"https://api.github.com/repos/{repo}/releases/assets/{asset['id']}"
                delete_cmd = f"""curl -X DELETE \\
  -H "Authorization: token {token}" \\
  -H "Accept: application/vnd.github.v3+json" \\
  "{delete_url}" """
                
                del_stdout, del_stderr, del_code = run_cmd(delete_cmd)
                if del_code == 0:
                    print(f"✓ Old .pkg deleted")
                else:
                    print(f"⚠️  Could not delete old .pkg: {del_stderr}")
        
    except json.JSONDecodeError as e:
        print(f"❌ Failed to parse response: {e}")
        sys.exit(1)
    
    # Upload new .pkg
    print(f"\n📤 Uploading {pkg_file}...")
    
    upload_cmd = f"""curl -X POST \\
  -H "Authorization: token {token}" \\
  -H "Content-Type: application/octet-stream" \\
  --data-binary @{pkg_path} \\
  "{upload_url}?name={pkg_file}" """
    
    stdout, stderr, code = run_cmd(upload_cmd)
    
    if code != 0:
        print(f"❌ Upload failed: {stderr}")
        sys.exit(1)
    
    try:
        asset_response = json.loads(stdout)
        if "id" in asset_response:
            download_url = asset_response["browser_download_url"]
            print(f"✅ {pkg_file} uploaded successfully!")
            print(f"   Asset ID: {asset_response['id']}")
            print(f"   Size: {asset_response['size'] / (1024*1024):.1f} MB")
            print(f"   Download: {download_url}")
            print(f"\n🎉 Release updated!")
            print(f"   View at: https://github.com/{repo}/releases/tag/{tag}")
        else:
            print(f"❌ Unexpected response: {asset_response}")
            sys.exit(1)
            
    except json.JSONDecodeError as e:
        print(f"❌ Failed to parse upload response: {e}")
        print(f"   Response: {stdout}")
        sys.exit(1)

if __name__ == "__main__":
    main()