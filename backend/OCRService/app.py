"""Local PaddleOCR adapter for MoonStone FileService."""

from __future__ import annotations

import json
import tempfile
from functools import lru_cache
from pathlib import Path
from typing import Any

import fitz
from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from paddleocr import PaddleOCR

app = FastAPI(title="MoonStone Local OCR", version="1.0")
MAX_UPLOAD_BYTES = 10 * 1024 * 1024
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}
JOB_PROGRESS: dict[str, dict[str, object]] = {}


@lru_cache(maxsize=2)
def engine(mode: str) -> PaddleOCR:
    """Load the small model for quick jobs and the medium default model for standard jobs."""
    options: dict[str, object] = {
        "lang": "ch",
        "use_doc_orientation_classify": False,
        "use_doc_unwarping": False,
        "use_textline_orientation": False,
        "engine": "paddle",
    }
    if mode == "quick":
        options.update({
            "text_detection_model_name": "PP-OCRv6_small_det",
            "text_recognition_model_name": "PP-OCRv6_small_rec",
        })
    return PaddleOCR(**options)


def result_to_lines(item: Any) -> list[str]:
    """Read the stable text list from PaddleOCR 3.x result objects."""
    if hasattr(item, "json"):
        item = item.json
        item = item() if callable(item) else item
    if isinstance(item, str):
        item = json.loads(item)
    if not isinstance(item, dict):
        return []
    payload = item.get("res", item)
    return [str(text).strip() for text in payload.get("rec_texts", []) if str(text).strip()]


def recognize_image(image_path: Path, mode: str) -> list[str]:
    results = engine(mode).predict(str(image_path))
    lines: list[str] = []
    for result in results:
        lines.extend(result_to_lines(result))
    return lines


def render_pdf(pdf_path: Path, output_dir: Path, mode: str) -> list[Path]:
    document = fitz.open(pdf_path)
    try:
        pages: list[Path] = []
        for number, page in enumerate(document, start=1):
            image_path = output_dir / f"page-{number}.png"
            scale = 1.5 if mode == "quick" else 2
            page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False).save(image_path)
            pages.append(image_path)
        return pages
    finally:
        document.close()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "live"}


@app.get("/v1/ocr/jobs/{job_id}")
def ocr_progress(job_id: str) -> dict[str, object]:
    return JOB_PROGRESS.get(job_id, {"status": "UNKNOWN", "currentPage": 0, "totalPages": 0, "phase": "WAITING"})


@app.post("/v1/ocr")
def ocr(file: UploadFile = File(...), x_ocr_job_id: str | None = Header(default=None), x_ocr_mode: str | None = Header(default=None)) -> dict[str, list[dict[str, object]]]:
    # A sync endpoint runs in FastAPI's worker thread pool, leaving the event loop free for progress polling.
    data = file.file.read()
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, "The file exceeds the 10 MB limit.")

    mode = (x_ocr_mode or "standard").strip().lower()
    if mode not in {"quick", "standard"}:
        raise HTTPException(400, "OCR mode must be quick or standard.")

    suffix = Path(file.filename or "upload").suffix.lower()
    content_type = (file.content_type or "").lower()
    is_pdf = suffix == ".pdf" or content_type == "application/pdf" or data.startswith(b"%PDF-")
    is_png = suffix == ".png" or content_type == "image/png" or data.startswith(b"\x89PNG\r\n\x1a\n")
    is_jpeg = suffix in {".jpg", ".jpeg"} or content_type == "image/jpeg" or data.startswith(b"\xff\xd8\xff")
    if not (is_pdf or is_png or is_jpeg):
        raise HTTPException(415, "Only PDF, JPG and PNG files are supported.")

    with tempfile.TemporaryDirectory(prefix="moonstone-ocr-") as directory:
        temporary = Path(directory)
        source = temporary / ("input.pdf" if is_pdf else "input.png" if is_png else "input.jpg")
        source.write_bytes(data)

        images = render_pdf(source, temporary, mode) if is_pdf else [source]
        if x_ocr_job_id:
            JOB_PROGRESS[x_ocr_job_id] = {"status": "RUNNING", "currentPage": 0, "totalPages": len(images), "phase": "RECOGNIZING", "mode": mode}
        pages = []
        try:
            for number, image in enumerate(images, start=1):
                if x_ocr_job_id:
                    JOB_PROGRESS[x_ocr_job_id] = {"status": "RUNNING", "currentPage": number - 1, "totalPages": len(images), "phase": "RECOGNIZING", "mode": mode}
                pages.append({"pageNumber": number, "lines": recognize_image(image, mode)})
                if x_ocr_job_id:
                    JOB_PROGRESS[x_ocr_job_id] = {"status": "RUNNING", "currentPage": number, "totalPages": len(images), "phase": "RECOGNIZING", "mode": mode}
            if x_ocr_job_id:
                JOB_PROGRESS[x_ocr_job_id] = {"status": "SUCCEEDED", "currentPage": len(images), "totalPages": len(images), "phase": "COMPLETED", "mode": mode}
            return {"pages": pages}
        except Exception:
            if x_ocr_job_id:
                JOB_PROGRESS[x_ocr_job_id] = {"status": "FAILED", "currentPage": 0, "totalPages": len(images), "phase": "FAILED", "mode": mode}
            raise
