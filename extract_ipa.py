import zipfile
import os
import shutil

ipa_path = r'C:\TrollAutoTouch\TrollAutoScript2.3.6.tipa'
extract_dir = r'C:\TrollAutoTouch\_reverse_eng'

if os.path.exists(extract_dir):
    shutil.rmtree(extract_dir)
os.makedirs(extract_dir, exist_ok=True)

with zipfile.ZipFile(ipa_path, 'r') as zf:
    zf.extractall(extract_dir)
    print(f"Extracted {len(zf.namelist())} files")
    for name in zf.namelist()[:30]:
        print(f"  {name}")
    
    # Find the app bundle
    app_files = [n for n in zf.namelist() if '.app/' in n and n.endswith('.app/')]
    if app_files:
        print(f"\nApp bundle found at: {app_files[0]}")
        # List contents of the app bundle
        app_prefix = app_files[0]
        app_contents = [n for n in zf.namelist() if n.startswith(app_prefix)]
        print(f"\nContents of {app_prefix}:")
        for c in app_contents[:50]:
            print(f"  {c}")
        if len(app_contents) > 50:
            print(f"  ... and {len(app_contents) - 50} more files")

print("\nDone!")
