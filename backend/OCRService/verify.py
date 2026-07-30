"""Smoke test for a running local OCR service."""

import io

import httpx
from PIL import Image, ImageDraw

image = Image.new("RGB", (500, 160), "white")
ImageDraw.Draw(image).text((24, 50), "MoonStone OCR 2026", fill="black", font_size=32)
buffer = io.BytesIO()
image.save(buffer, format="PNG")

with httpx.Client(trust_env=False, timeout=300) as client:
    response = client.post(
        "http://127.0.0.1:5110/v1/ocr",
        files={"file": ("ocr-smoke-test.png", buffer.getvalue(), "image/png")},
    )
response.raise_for_status()
pages = response.json().get("pages", [])
if not any(page.get("lines") for page in pages):
    raise RuntimeError(f"OCR returned no text: {response.text}")
print(response.text)
