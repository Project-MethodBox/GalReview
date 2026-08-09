"""Local PaddleOCR adapter for MoonStone FileService."""

from __future__ import annotations

import json
import os
import re
import tempfile
import threading
import time
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from threading import Lock
from typing import Any

# Keep PaddleX model files beside OCRService instead of the user-profile cache.
# This avoids inherited ACL issues and makes deployment/model cleanup self-contained.
os.environ.setdefault("PADDLE_PDX_CACHE_HOME", str(Path(__file__).resolve().parent / "models"))
os.environ.setdefault("PADDLE_PDX_MODEL_SOURCE", "BOS")

import fitz
from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from paddleocr import FormulaRecognitionPipeline, PaddleOCR

app = FastAPI(title="MoonStone Local OCR", version="1.0")
MAX_UPLOAD_BYTES = 10 * 1024 * 1024
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}
JOB_PROGRESS: dict[str, dict[str, object]] = {}
# Paddle/oneDNN inference is not safe to run concurrently in one Python process.
OCR_INFERENCE_LOCK = Lock()
CANCELLED_JOBS: set[str] = set()


def ensure_not_cancelled(job_id: str | None) -> None:
    if job_id and job_id in CANCELLED_JOBS:
        current = JOB_PROGRESS.get(job_id, {})
        JOB_PROGRESS[job_id] = {
            "status": "CANCELLED",
            "currentPage": current.get("currentPage", 0),
            "totalPages": current.get("totalPages", 0),
            "phase": "CANCELLED",
            "mode": current.get("mode", "standard"),
        }
        raise HTTPException(409, "OCR job was cancelled.")


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


@dataclass(frozen=True)
class TextRegion:
    text: str
    left: float
    top: float
    right: float
    bottom: float


@dataclass(frozen=True)
class FormulaRegion:
    latex: str
    left: float
    top: float
    right: float
    bottom: float


def result_to_payload(item: Any) -> dict[str, Any]:
    if hasattr(item, "json"):
        item = item.json
        item = item() if callable(item) else item
    if isinstance(item, str):
        item = json.loads(item)
    if not isinstance(item, dict):
        return {}
    payload = item.get("res", item)
    return payload if isinstance(payload, dict) else {}


def rect(value: Any) -> tuple[float, float, float, float] | None:
    if not isinstance(value, (list, tuple)) or len(value) < 4:
        return None
    try:
        left, top, right, bottom = (float(value[index]) for index in range(4))
    except (TypeError, ValueError):
        return None
    return min(left, right), min(top, bottom), max(left, right), max(top, bottom)


def overlap_area(first: TextRegion, second: FormulaRegion) -> float:
    width = max(0.0, min(first.right, second.right) - max(first.left, second.left))
    height = max(0.0, min(first.bottom, second.bottom) - max(first.top, second.top))
    return width * height


def is_choice_label(text: str) -> str | None:
    match = re.match(r"^\s*(\([A-Za-z]\))", text)
    return match.group(1) if match else None


def remaining_text_after_formula_regions(region: TextRegion, formulas: list[FormulaRegion]) -> list[tuple[float, float, str]]:
    """Keep only non-formula OCR text and retain its original horizontal position."""
    label = is_choice_label(region.text)
    if label:
        return [(region.left, region.left + (region.right - region.left) * len(label) / max(len(region.text), 1), label)]

    width = max(region.right - region.left, 1.0)
    ranges: list[tuple[int, int]] = []
    for formula in formulas:
        if overlap_area(region, formula) <= 0:
            continue
        start = max(0, min(len(region.text), round((formula.left - region.left) / width * len(region.text))))
        end = max(start, min(len(region.text), round((formula.right - region.left) / width * len(region.text))))
        ranges.append((start, end))
    if not ranges:
        return [(region.left, region.right, region.text)]

    merged: list[list[int]] = []
    for start, end in sorted(ranges):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])

    parts: list[tuple[float, float, str]] = []
    cursor = 0
    for start, end in merged:
        if cursor < start:
            text = region.text[cursor:start].strip()
            if text:
                parts.append((region.left + width * cursor / len(region.text), region.left + width * start / len(region.text), text))
        cursor = max(cursor, end)
    if cursor < len(region.text):
        text = region.text[cursor:].strip()
        if text:
            parts.append((region.left + width * cursor / len(region.text), region.right, text))
    return parts


@lru_cache(maxsize=1)
def formula_engine() -> FormulaRecognitionPipeline:
    """Detect formula regions and transcribe them with PP-FormulaNet_plus-M."""
    return FormulaRecognitionPipeline(
        formula_recognition_model_name="PP-FormulaNet_plus-M",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_layout_detection=True,
    )


def recognize_formula_regions(image_path: Path) -> list[FormulaRegion]:
    formulas: list[FormulaRegion] = []
    for result in formula_engine().predict(str(image_path)):
        payload = result_to_payload(result)
        for formula in payload.get("formula_res_list", []):
            if not isinstance(formula, dict):
                continue
            latex = str(formula.get("rec_formula", "")).strip()
            regions = formula.get("dt_polys", [])
            bounds = rect(regions[0]) if isinstance(regions, list) and regions else None
            if latex and bounds:
                formulas.append(FormulaRegion(latex, *bounds))
    return formulas


def recognize_text_regions(image_path: Path, mode: str) -> list[TextRegion]:
    regions: list[TextRegion] = []
    for result in engine(mode).predict(str(image_path)):
        payload = result_to_payload(result)
        texts = payload.get("rec_texts", [])
        boxes = payload.get("rec_boxes", [])
        if not isinstance(texts, list) or not isinstance(boxes, list):
            continue
        for text, box in zip(texts, boxes):
            value = str(text).strip()
            bounds = rect(box)
            if value and bounds:
                regions.append(TextRegion(value, *bounds))
    return regions


def merge_ocr_regions(text_regions: list[TextRegion], formula_regions: list[FormulaRegion]) -> list[str]:
    """Replace formula-overlapping OCR and reconstruct rows, including two-column pages."""
    segments: list[tuple[float, float, float, str]] = []
    for region in text_regions:
        overlaps = [formula for formula in formula_regions if overlap_area(region, formula) > 0]
        for left, right, text in remaining_text_after_formula_regions(region, overlaps):
            segments.append(((region.top + region.bottom) / 2, left, right, text))
    for formula in formula_regions:
        segments.append(((formula.top + formula.bottom) / 2, formula.left, formula.right, f"$${formula.latex}$$"))

    segments.sort(key=lambda item: (item[0], item[1]))
    visual_rows: list[list[tuple[float, float, float, str]]] = []
    for segment in segments:
        if not visual_rows or abs(segment[0] - visual_rows[-1][0][0]) > 18:
            visual_rows.append([segment])
        else:
            visual_rows[-1].append(segment)

    lines: list[str] = []
    for row in visual_rows:
        columns: list[list[tuple[float, float, float, str]]] = []
        for segment in sorted(row, key=lambda item: item[1]):
            if columns and segment[1] - columns[-1][-1][2] > 100:
                columns.append([segment])
            elif columns:
                columns[-1].append(segment)
            else:
                columns.append([segment])
        lines.extend(" ".join(text for _, _, _, text in column) for column in columns)
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


@app.post("/v1/ocr/jobs/{job_id}/cancel", status_code=202)
def cancel_ocr_job(job_id: str) -> dict[str, object]:
    CANCELLED_JOBS.add(job_id)
    current = JOB_PROGRESS.get(job_id, {})
    JOB_PROGRESS[job_id] = {
        "status": "CANCELLED",
        "currentPage": current.get("currentPage", 0),
        "totalPages": current.get("totalPages", 0),
        "phase": "CANCELLED",
        "mode": current.get("mode", "standard"),
    }
    return {"jobId": job_id, "status": "CANCELLED"}


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
            JOB_PROGRESS[x_ocr_job_id] = {"status": "RUNNING", "currentPage": 0, "totalPages": len(images), "phase": "RECOGNIZING", "mode": mode, "created_at": time.time()}
        pages = []
        try:
            for number, image in enumerate(images, start=1):
                ensure_not_cancelled(x_ocr_job_id)
                if x_ocr_job_id:
                    JOB_PROGRESS[x_ocr_job_id] = {"status": "RUNNING", "currentPage": number - 1, "totalPages": len(images), "phase": "RECOGNIZING", "mode": mode, "created_at": time.time()}
                # Serialize native Paddle/oneDNN calls. A queued cancelled job leaves
                # within 250 ms; an active one stops after its current model call.
                while not OCR_INFERENCE_LOCK.acquire(timeout=0.25):
                    ensure_not_cancelled(x_ocr_job_id)
                try:
                    ensure_not_cancelled(x_ocr_job_id)
                    text_regions = recognize_text_regions(image, mode)
                    ensure_not_cancelled(x_ocr_job_id)
                    formula_regions: list[FormulaRegion] = []
                    if mode == "standard":
                        if x_ocr_job_id:
                            JOB_PROGRESS[x_ocr_job_id] = {"status": "RUNNING", "currentPage": number - 1, "totalPages": len(images), "phase": "FORMULA_RECOGNITION", "mode": mode, "created_at": time.time()}
                        formula_regions = recognize_formula_regions(image)
                        ensure_not_cancelled(x_ocr_job_id)
                    lines = merge_ocr_regions(text_regions, formula_regions)
                    formulas = [formula.latex for formula in formula_regions]
                finally:
                    OCR_INFERENCE_LOCK.release()
                pages.append({"pageNumber": number, "lines": lines, "formulas": formulas})
                if x_ocr_job_id:
                    JOB_PROGRESS[x_ocr_job_id] = {"status": "RUNNING", "currentPage": number, "totalPages": len(images), "phase": "RECOGNIZING", "mode": mode, "created_at": time.time()}
            ensure_not_cancelled(x_ocr_job_id)
            if x_ocr_job_id:
                JOB_PROGRESS[x_ocr_job_id] = {"status": "SUCCEEDED", "currentPage": len(images), "totalPages": len(images), "phase": "COMPLETED", "mode": mode, "created_at": time.time()}
            return {"pages": pages}
        except HTTPException:
            raise
        except Exception:
            if x_ocr_job_id:
                JOB_PROGRESS[x_ocr_job_id] = {"status": "FAILED", "currentPage": 0, "totalPages": len(images), "phase": "FAILED", "mode": mode, "created_at": time.time()}
            raise


def cleanup_old_jobs():
    """Clean up job progress entries older than 1 hour."""
    cutoff = time.time() - 3600
    to_remove: list[str] = []
    for job_id, info in JOB_PROGRESS.items():
        created_at = info.get("created_at")
        if isinstance(created_at, (int, float)) and created_at < cutoff:
            to_remove.append(job_id)
    for job_id in to_remove:
        JOB_PROGRESS.pop(job_id, None)
        CANCELLED_JOBS.discard(job_id)
    # Schedule next cleanup in 10 minutes
    threading.Timer(600, cleanup_old_jobs).start()


# Start cleanup timer when app initializes
cleanup_old_jobs()
