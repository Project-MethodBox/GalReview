"""End-to-end OCR smoke test through FileService."""

import io
import time

import httpx
from PIL import Image, ImageDraw

headers = {
    "X-Gateway-Key": "moonstone-local-gateway-key",
    "X-User-Id": "11111111-1111-1111-1111-111111111111",
}
image = Image.new("RGB", (500, 160), "white")
ImageDraw.Draw(image).text((24, 50), "MoonStone OCR 2026", fill="black", font_size=32)
buffer = io.BytesIO()
image.save(buffer, format="PNG")

with httpx.Client(base_url="http://127.0.0.1:5103", headers=headers, trust_env=False, timeout=60) as client:
    upload = client.post(
        "/api/v1/materials",
        files={"file": ("ocr-smoke-test.png", buffer.getvalue(), "image/png")},
        data={"displayName": "OCR smoke test"},
    )
    upload.raise_for_status()
    material_id = upload.json()["data"]["materialId"]
    try:
        job = client.post(f"/api/v1/materials/{material_id}/ingestion-jobs", json={"parserVersion": "files-ocr-v1", "enableOcr": True})
        job.raise_for_status()
        job_id = job.json()["data"]["jobId"]
        for _ in range(60):
            state = client.get(f"/api/v1/ingestion-jobs/{job_id}").json()["data"]
            if state["status"] == "SUCCEEDED":
                break
            if state["status"] == "FAILED":
                raise RuntimeError(state)
            time.sleep(0.5)
        else:
            raise TimeoutError("FileService OCR job did not finish in time.")
        preview = client.get(f"/api/v1/materials/{material_id}/extracted-text-preview")
        preview.raise_for_status()
        text = preview.json()["data"]["text"]
        if "MoonStone OCR 2026" not in text:
            raise RuntimeError(f"Unexpected extracted text: {text}")
        print(text)
    finally:
        deleted = client.delete(f"/api/v1/materials/{material_id}")
        deleted.raise_for_status()
