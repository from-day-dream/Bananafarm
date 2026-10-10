"""
Output archiving for image sequences and partial frames.
Ported from the old r2_storage.py _zip_files (R2 upload removed).
"""
import os
import zipfile
from typing import List, Optional


def zip_outputs(files: List[str], zip_name: str) -> Optional[str]:
    """
    Create a flat zip archive of the given files in /tmp.

    Returns the zip path, or None on failure.
    """
    try:
        zip_path = f"/tmp/{zip_name}"

        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
            for file_path in files:
                if os.path.exists(file_path):
                    arcname = os.path.basename(file_path)
                    zipf.write(file_path, arcname=arcname)
                    print(f"  ✓ Added: {arcname}")
                else:
                    print(f"  ⚠️ Skipping missing file: {file_path}")

        if os.path.exists(zip_path):
            zip_size = os.path.getsize(zip_path)
            print(f"✅ Zip created: {zip_size / (1024 * 1024):.2f} MB")
            return zip_path

        print("❌ Zip file not created")
        return None

    except Exception as e:
        print(f"❌ Error creating zip: {e}")
        return None
