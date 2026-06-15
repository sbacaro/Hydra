#!/usr/bin/env python3
"""
Delete existing release and create new one with .pkg for Hydra Audio.
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
        print("   Then run: export GITHUB_TOKEN=\"ghp_your_token_here\"")
        sys.exit(1)
    
    print(f"🔄 Recreating release: {release_name}")
    print(f"   Tag: {tag}")
    print(f"   Repo: {repo}")
    
    # Step 1: Delete existing release
    print("\n🗑️  Deleting existing release...")
    
    # Get release ID
    api_url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    
    stdout, stderr, code = run_cmd(f"""curl -s \\
  -H "Authorization: token {token}" \\
  -H "Accept: application/vnd.github.v3+json" \\
  "{api_url}" """)
    
    if code == 0:
        try:
            response = json.loads(stdout)
            if "id" in response:
                release_id = response["id"]
                print(f"   Found release ID: {release_id}")
                
                # Delete release
                delete_cmd = f"""curl -X DELETE \\
  -H "Authorization: token {token}" \\
  -H "Accept: application/vnd.github.v3+json" \\
  "https://api.github.com/repos/{repo}/releases/{release_id}" """
                
                del_stdout, del_stderr, del_code = run_cmd(delete_cmd)
                if del_code == 0:
                    print(f"   ✅ Release deleted")
                else:
                    print(f"   ⚠️  Could not delete release: {del_stderr}")
            else:
                print(f"   ℹ️  No existing release found")
        except json.JSONDecodeError:
            print(f"   ℹ️  No existing release found")
    else:
        print(f"   ℹ️  No existing release found")
    
    # Step 2: Delete existing tag (to recreate it)
    print("\n🏷️  Deleting existing tag...")
    delete_tag_cmd = f"""curl -X DELETE \\
  -H "Authorization: token {token}" \\
  -H "Accept: application/vnd.github.v3+json" \\
  "https://api.github.com/repos/{repo}/git/refs/tags/{tag}" """
    
    tag_stdout, tag_stderr, tag_code = run_cmd(delete_tag_cmd)
    if tag_code == 0:
        print(f"   ✅ Tag deleted")
    else:
        print(f"   ℹ️  Tag didn't exist or couldn't be deleted")
    
    # Step 3: Create tag
    print("\n🏷️  Creating new tag...")
    
    # Get current commit hash
    commit_cmd = f"""curl -s \\
  -H "Authorization: token {token}" \\
  -H "Accept: application/vnd.github.v3+json" \\
  "https://api.github.com/repos/{repo}/git/refs/heads/main" """
    
    commit_stdout, commit_stderr, commit_code = run_cmd(commit_cmd)
    if commit_code != 0:
        print(f"❌ Failed to get commit: {commit_stderr}")
        sys.exit(1)
    
    try:
        commit_data = json.loads(commit_stdout)
        commit_sha = commit_data["object"]["sha"]
        print(f"   Using commit: {commit_sha[:8]}")
    except (json.JSONDecodeError, KeyError):
        print(f"❌ Could not parse commit data")
        sys.exit(1)
    
    # Create tag
    tag_data = {
        "tag": tag,
        "message": f"Release {release_name}",
        "object": commit_sha,
        "type": "commit"
    }
    
    create_tag_cmd = f"""curl -X POST \\
  -H "Authorization: token {token}" \\
  -H "Content-Type: application/json" \\
  -d '{json.dumps(tag_data)}' \\
  "https://api.github.com/repos/{repo}/git/tags" """
    
    tag_stdout, tag_stderr, tag_code = run_cmd(create_tag_cmd)
    if tag_code != 0:
        print(f"❌ Failed to create tag: {tag_stderr}")
        sys.exit(1)
    
    try:
        tag_response = json.loads(tag_stdout)
        tag_sha = tag_response["sha"]
        print(f"   ✅ Tag created: {tag_sha[:8]}")
    except json.JSONDecodeError:
        print(f"❌ Could not parse tag response")
        sys.exit(1)
    
    # Create reference
    ref_data = {
        "ref": f"refs/tags/{tag}",
        "sha": tag_sha
    }
    
    ref_cmd = f"""curl -X POST \\
  -H "Authorization: token {token}" \\
  -H "Content-Type: application/json" \\
  -d '{json.dumps(ref_data)}' \\
  "https://api.github.com/repos/{repo}/git/refs" """
    
    ref_stdout, ref_stderr, ref_code = run_cmd(ref_cmd)
    if ref_code == 0:
        print(f"   ✅ Tag reference created")
    else:
        print(f"   ⚠️  Could not create tag reference: {ref_stderr}")
    
    # Step 4: Read release notes
    notes_file = Path(__file__).parent / "RELEASE_NOTES_0.15.1.md"
    if not notes_file.exists():
        print(f"❌ Error: {notes_file} not found")
        sys.exit(1)
    
    with open(notes_file) as f:
        body = f.read()
    
    # Step 5: Create new release
    print("\n📦 Creating new release...")
    
    release_data = {
        "tag_name": tag,
        "name": release_name,
        "body": body,
        "draft": False,
        "prerelease": True
    }
    
    create_release_cmd = f"""curl -X POST \\
  -H "Authorization: token {token}" \\
  -H "Content-Type: application/json" \\
  -d '{json.dumps(release_data)}' \\
  "https://api.github.com/repos/{repo}/releases" """
    
    stdout, stderr, code = run_cmd(create_release_cmd)
    
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
        
        print(f"   ✅ Release created (ID: {release_id})")
        
    except json.JSONDecodeError as e:
        print(f"❌ Failed to parse response: {e}")
        sys.exit(1)
    
    # Step 6: Upload .pkg asset
    pkg_file = Path(__file__).parent / "Hydra-0.15.1.pkg"
    if not pkg_file.exists():
        print(f"❌ Error: {pkg_file} not found")
        print("   Run ./build_pkg.sh first")
        sys.exit(1)
    
    print(f"\n📤 Uploading .pkg: {pkg_file.name}")
    file_size = pkg_file.stat().st_size / (1024 * 1024)
    print(f"   Size: {file_size:.1f} MB")
    
    upload_cmd = f"""curl -X POST \\
  -H "Authorization: token {token}" \\
  -H "Content-Type: application/octet-stream" \\
  --data-binary @{pkg_file} \\
  "{upload_url}?name={pkg_file.name}" """
    
    stdout, stderr, code = run_cmd(upload_cmd)
    
    if code != 0:
        print(f"❌ Upload failed: {stderr}")
        sys.exit(1)
    
    try:
        asset_response = json.loads(stdout)
        if "id" in asset_response:
            download_url = asset_response["browser_download_url"]
            print(f"   ✅ .pkg uploaded successfully")
            print(f"   Download: {download_url}")
        else:
            print(f"❌ Unexpected response: {asset_response}")
            sys.exit(1)
            
    except json.JSONDecodeError as e:
        print(f"❌ Failed to parse upload response: {e}")
        sys.exit(1)
    
    # Step 7: (Optional) Upload ZIP as well if it exists
    zip_file = Path(__file__).parent / "Hydra-0.15.1-beta.zip"
    if zip_file.exists():
        print(f"\n📤 Uploading ZIP: {zip_file.name}")
        zip_size = zip_file.stat().st_size / (1024 * 1024)
        print(f"   Size: {zip_size:.1f} MB")
        
        zip_upload_cmd = f"""curl -X POST \\
  -H "Authorization: token {token}" \\
  -H "Content-Type: application/zip" \\
  --data-binary @{zip_file} \\
  "{upload_url}?name={zip_file.name}" """
        
        zip_stdout, zip_stderr, zip_code = run_cmd(zip_upload_cmd)
        
        if zip_code == 0:
            try:
                zip_response = json.loads(zip_stdout)
                if "id" in zip_response:
                    print(f"   ✅ ZIP uploaded successfully")
            except json.JSONDecodeError:
                print(f"   ⚠️  Could not parse ZIP upload response")
    
    print(f"\n🎉 Release recreation complete!")
    print(f"   URL: https://github.com/{repo}/releases/tag/{tag}")
    print(f"   Assets: .pkg installer + ZIP archive")

if __name__ == "__main__":
    main()