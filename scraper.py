"""
FastAPI + Scrapy(+Playwright) crawler that:
- Accepts JSON: {"url": "<base-url>", "depth": <int>}
- Crawls only the same site up to given depth (0=only base page, 1=base + its links, 2=...).
- Writes ONE PDF per visited URL to a temp folder (clean, visible text only).
- Returns a ZIP with all PDFs.

Run:
  pip install -r requirements.txt
  uvicorn app:app --reload
Test:
  curl -X POST "http://127.0.0.1:8000/scrape" -H "Content-Type: application/json" \
       -d '{"url":"https://example.com", "depth":1}' --output result.zip

Notes:
- "Production" extraction strategy here keeps *all visible* text without using "main-content"
  algorithms (which may drop sidebars/tables). We aggressively remove scripts/styles/hidden
  nodes and normalize whitespace so PDFs read cleanly.
"""

# ---------------------------
# Choose Twisted reactor for asyncio (must be first)
# ---------------------------
import os
os.environ.setdefault(
    "TWISTED_REACTOR",
    "twisted.internet.asyncioreactor.AsyncioSelectorReactor"
)

import asyncio
from twisted.internet import asyncioreactor
try:
    asyncioreactor.install(asyncio.get_event_loop())
except Exception:
    pass

# ---------------------------
# Standard libs
# ---------------------------
import io
import re
import zipfile
import tempfile
import hashlib
import datetime
from urllib.parse import urlparse, urldefrag, urlsplit, urlunsplit, parse_qsl, urlencode
from pathlib import Path
import shutil
import subprocess
import sys

# ---------------------------
# FastAPI / Pydantic
# ---------------------------
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, HttpUrl, Field

# ---------------------------
# Scrapy / Twisted
# ---------------------------
import scrapy
from scrapy.crawler import CrawlerRunner
from scrapy.linkextractors import LinkExtractor
from scrapy.utils.log import configure_logging

# ---------------------------
# PDF (ReportLab)
# ---------------------------
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer
from reportlab.lib.units import inch
from reportlab.lib.enums import TA_LEFT

# ---------------------------
# HTML parsing / cleaning
# ---------------------------
from lxml import html
from lxml.html.clean import Cleaner

# ---------------------------
# Playwright (browser bootstrap)
# ---------------------------
BROWSERS_PATH = os.environ.get(
    "PLAYWRIGHT_BROWSERS_PATH",
    str(Path.home() / ".cache" / "ms-playwright")
)
os.environ["PLAYWRIGHT_BROWSERS_PATH"] = BROWSERS_PATH  # ensure both sides agree

def _chromium_present() -> bool:
    p = Path(BROWSERS_PATH)
    return p.exists() and any(p.glob("chromium*/*/chrome*"))  # crude but works

# ---------------------------
# FastAPI app (single instance)
# ---------------------------
app = FastAPI(title="Scrape-to-PDF", version="1.1.0")

@app.on_event("startup")
def ensure_playwright_browsers():
    if not shutil.which("playwright"):
        raise RuntimeError("The 'playwright' CLI is not on PATH (install in this venv).")
    if not _chromium_present():
        try:
            subprocess.run(
                ["playwright", "install", "chromium", "--with-deps", "--force"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
        except subprocess.CalledProcessError as e:
            print("Playwright install failed:\n", e.stdout, file=sys.stderr)
            raise

# ---------------------------
# FastAPI schema
# ---------------------------
class CrawlRequest(BaseModel):
    url: HttpUrl = Field(..., description="Base site URL to start scraping")
    depth: int = Field(1, ge=0, le=5, description="Crawl depth (0=only base page, 1=base+its links, 2=their links too, ...)")

# ---------------------------
# Utilities
# ---------------------------
def same_site_allowed_domains(base_url: str):
    parsed = urlparse(base_url)
    host = (parsed.hostname or "").lower()
    allow = set()
    if not host:
        return []
    allow.add(host)
    # add apex (example.com) and www.example.com variants both ways
    naked = host[4:] if host.startswith("www.") else host
    allow.add(naked)
    allow.add(f"www.{naked}")
    parts = naked.split(".")
    if len(parts) > 2:
        allow.add(".".join(parts[-2:]))
    return list(allow)

def sanitize_filename_from_url(url: str) -> str:
    clean_url, _ = urldefrag(url)  # remove #fragment
    h = hashlib.md5(clean_url.encode("utf-8")).hexdigest()[:10]
    parsed = urlparse(clean_url)
    stem = re.sub(r"[^a-zA-Z0-9]+", "-", f"{parsed.netloc}{parsed.path}")[:80].strip("-")
    return f"{stem or 'page'}-{h}.pdf"

def _strip_tracking(u: str) -> str:
    sp = urlsplit(u)
    q = [(k, v) for k, v in parse_qsl(sp.query, keep_blank_values=True)
         if not k.lower().startswith(("utm_", "fbclid", "gclid", "mc_eid"))]
    return urlunsplit((sp.scheme, sp.netloc, sp.path, urlencode(q), ""))  # drop fragment

# ---------------------------
# HTML → Clean visible text
# ---------------------------
# Aggressive cleaner for production: keeps links/text but removes all scripts/styles/JS/etc.
CLEANER = Cleaner(
    scripts=True, javascript=True, style=True, inline_style=True,
    links=False, meta=True, page_structure=False, remove_unknown_tags=False,
    annoying_tags=True, frames=True, forms=True, embedded=True,
    kill_tags=[
        # Non-content/interactive or heavy visual tags that produce noise in text
        "noscript", "template", "svg", "canvas", "iframe", "picture", "source",
        "video", "audio", "track", "map", "area",
        # Inputs/buttons/forms already handled by forms=True, but keep explicit:
        "button", "input", "select", "textarea"
    ],
)

HIDE_XPATH = (
    '//*[@hidden or @aria-hidden="true" or contains(@style,"display:none") '
    'or contains(@style,"visibility:hidden")]'
)

def visible_text_from_html(document_html: str, base_url: str) -> str:
    """
    Keep all human-visible text from the rendered DOM while removing scripts, styles,
    hidden elements, and UI-only controls. Avoids dropping real content (no "main-only"
    heuristics). Produces normalized, readable paragraphs.
    """
    # Parse + base URL for proper handling of relative links (if needed later)
    try:
        root = html.fromstring(document_html, base_url=str(base_url))
    except Exception:
        # fallback: crude text-only if parsing fails
        return " ".join(document_html.split())

    # Clean heavy non-text elements / JS / CSS
    root = CLEANER.clean_html(root)

    # Remove hidden elements (common cases)
    for el in root.xpath(HIDE_XPATH):
        parent = el.getparent()
        if parent is not None:
            parent.remove(el)

    # Remove elements that are practically empty or purely decorative
    for el in root.xpath('//*[self::svg or self::canvas or self::picture or self::source]'):
        parent = el.getparent()
        if parent is not None:
            parent.remove(el)

    # Get full visible text content
    text = root.text_content()

    # Normalize whitespace (collapse runs, keep sentence spacing)
    text = re.sub(r"[ \t\r\f\v]+", " ", text)
    # Normalize weird NBSPs etc.
    text = text.replace("\xa0", " ")
    # Convert multiple blank lines to just one
    text = re.sub(r"\n{3,}", "\n\n", text)
    # Add basic paragraph boundaries based on block-ish tags by re-parsing nodes (lightweight)
    # (This is kept simple to avoid over-aggressive splitting.)
    text = "\n".join(line.strip() for line in text.splitlines())
    text = re.sub(r"\n{2,}", "\n\n", text).strip()

    # Heuristic: drop lines that look like leftover CSS/JS (very rare after CLEANER, but safe)
    lines = []
    for ln in text.splitlines():
        s = ln.strip()
        if not s:
            lines.append("")  # preserve paragraph breaks
            continue
        if len(s) > 300 and any(tok in s for tok in (":hover", ":root", "@media", "function(", "var ")):
            # likely leftover stylesheet or JS-y dump
            continue
        if s.count("{") + s.count("}") + s.count(";") > 4:
            continue
        lines.append(s)
    text = "\n".join(lines)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()

    return text

# ---------------------------
# Meta extraction (whitelist)
# ---------------------------
META_WHITELIST = {
    "description", "og:title", "og:description", "twitter:title", "twitter:description"
}

def meta_as_text(document_html: str) -> str:
    try:
        root = html.fromstring(document_html)
    except Exception:
        return ""
    parts = []
    for tag in root.xpath("//meta[@content]"):
        name = (tag.get("name") or tag.get("property") or "").strip().lower()
        if name in META_WHITELIST:
            content = (tag.get("content") or "").strip()
            if content:
                parts.append(f"{name}: {content}")
    return "\n".join(parts)

# ---------------------------
# PDF builder
# ---------------------------
def make_pdf(path: str, payload: dict):
    """
    Create a PDF for one page.
    payload keys: url, title, fetched_at, meta, text, outgoing_links
    """
    styles = getSampleStyleSheet()
    normal = ParagraphStyle(
        "Body",
        parent=styles["Normal"],
        alignment=TA_LEFT,
        fontSize=10,
        leading=13,
    )
    h1 = styles["Heading1"]
    h2 = styles["Heading2"]
    h3 = styles["Heading3"]

    doc = SimpleDocTemplate(path, pagesize=A4, title=payload.get("title") or payload["url"])
    story = []

    story.append(Paragraph(payload.get("title") or "(No title)", h1))
    story.append(Paragraph(payload["url"], normal))
    story.append(Spacer(1, 0.15 * inch))

    # story.append(Paragraph("Fetched at", h2))
    # story.append(Paragraph(payload["fetched_at"], normal))
    story.append(Spacer(1, 0.1 * inch))

    # META WRITING
    # if payload.get("meta"):
    #     story.append(Paragraph("Meta", h2))
    #     for line in payload["meta"].splitlines():
    #         if line.strip():
    #             story.append(Paragraph(line.strip(), normal))
    #     story.append(Spacer(1, 0.15 * inch))

    if payload.get("text"):
        story.append(Paragraph("Page Text", h2))
        # Split into paragraphs on blank lines if present; else chunk smartly.
        raw = payload["text"]

        # Prefer to keep author-supplied paragraphs if any:
        paragraphs = re.split(r"\n\s*\n", raw.strip())
        if len(paragraphs) < 2:  # fallback: break by long length
            paragraphs = [raw]

        for para in paragraphs:
            para = para.strip()
            if not para:
                continue
            # further chunk very long paragraphs to avoid ReportLab layout blowups
            while para:
                chunk = para[:1600]
                cut = chunk.rfind(" ")
                if cut == -1 or len(para) <= 1600:
                    piece = para
                    para = ""
                else:
                    piece = para[:cut]
                    para = para[cut + 1:]
                story.append(Paragraph(piece, normal))
                story.append(Spacer(1, 0.05 * inch))

    #OUTGOING LINKS
    # if payload.get("outgoing_links"):
    #     story.append(Spacer(1, 0.15 * inch))
    #     story.append(Paragraph("Outgoing links discovered", h3))
    #     for href in payload["outgoing_links"][:250]:
    #         story.append(Paragraph(href, normal))

    doc.build(story)

# ---------------------------
# Scrapy spider
# ---------------------------
class SiteToPDFSpider(scrapy.Spider):
    name = "site_to_pdf"
    custom_settings = {
        "LOG_ENABLED": True,
        "DOWNLOAD_TIMEOUT": 60,
        "RETRY_ENABLED": True,
        "RETRY_TIMES": 4,
        "CONCURRENT_REQUESTS": 8,
        "AUTOTHROTTLE_ENABLED": True,
        "AUTOTHROTTLE_START_DELAY": 0.5,
        "AUTOTHROTTLE_MAX_DELAY": 8.0,
        "AUTOTHROTTLE_TARGET_CONCURRENCY": 4.0,
        "COOKIES_ENABLED": False,
        "REDIRECT_ENABLED": True,
        "USER_AGENT": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
        ),
        "DEFAULT_REQUEST_HEADERS": {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "Upgrade-Insecure-Requests": "1",
        },

        # Ensure we use Playwright handler
        "DOWNLOAD_HANDLERS": {
            "http": "scrapy_playwright.handler.ScrapyPlaywrightDownloadHandler",
            "https": "scrapy_playwright.handler.ScrapyPlaywrightDownloadHandler",
        },
        "PLAYWRIGHT_BROWSER_TYPE": "chromium",
        "PLAYWRIGHT_DEFAULT_NAVIGATION_TIMEOUT": 60000,
        "PLAYWRIGHT_LAUNCH_OPTIONS": {"headless": True},

        # Crawl breadth-first so shallow pages (depth 0/1) finish first
        "DEPTH_PRIORITY": 1,
        "SCHEDULER_DISK_QUEUE": "scrapy.squeues.PickleFifoDiskQueue",
        "SCHEDULER_MEMORY_QUEUE": "scrapy.squeues.FifoMemoryQueue",

        # Only treat HTML as parseable (others are denied by extension list below anyway)
        "SPIDER_MIDDLEWARES": {
            "scrapy.spidermiddlewares.httperror.HttpErrorMiddleware": 50,
        },
    }

    def __init__(self, start_url: str, outdir: str, allowed_domains: list[str], **kwargs):
        super().__init__(**kwargs)
        self.start_urls = [start_url]
        self.outdir = outdir
        self.allowed_domains = allowed_domains
        # extract only same-site links; deny common binaries
        self.link_extractor = LinkExtractor(
            allow_domains=self.allowed_domains,
            tags=("a",),
            attrs=("href",),
            deny=(),
            deny_extensions=[
                "7z", "zip", "rar", "pdf", "jpg", "jpeg", "png", "gif", "svg",
                "webp", "avif", "mp4", "mp3", "avi", "mov", "wmv", "mkv", "iso"
            ],
        )

    def start_requests(self):
        yield scrapy.Request(
            self.start_urls[0],
            callback=self.parse,
            errback=self.errback_first,
            dont_filter=True,
            meta={
                "playwright": True,
                "playwright_page_methods": [
                    ("wait_for_load_state", {"state": "networkidle"}),
                ],
                # Use same context for all pages to keep cookies/session consistent if needed
                "playwright_context": "default",
            },
        )

    def errback_first(self, failure):
        # Create an error PDF for the start URL
        url = self.start_urls[0]
        filename = sanitize_filename_from_url(url)
        pdf_path = os.path.join(self.outdir, filename)
        payload = {
            "url": url,
            "title": "(Fetch error)",
            # "fetched_at": datetime.datetime.utcnow().isoformat() + "Z",
            "meta": "",
            "text": f"Failed to fetch {url}\n\n{repr(failure.value)}",
            "outgoing_links": [],
        }
        try:
            make_pdf(pdf_path, payload)
            self.logger.warning(f"Wrote ERROR PDF: {pdf_path}")
        except Exception as e:
            self.logger.error(f"Failed to write error PDF: {e}")

    def parse(self, response: scrapy.http.Response):
        url = response.url
        title = (response.xpath("//title/text()").get() or "").strip()

        # Use the rendered HTML for extraction
        doc_html = response.text

        # Clean, visible text (keeps *all* human-visible content; strips JS/CSS/hidden)
        text = visible_text_from_html(doc_html, base_url=url)

        # Curated meta (optional; won't pollute PDF)
        metas = meta_as_text(doc_html)

        # Discover outgoing same-site links (and record them)
        links = []
        for link in self.link_extractor.extract_links(response):
            href, _ = urldefrag(link.url)
            href = _strip_tracking(href)
            links.append(href)
            yield response.follow(
                href,
                callback=self.parse,
                meta={
                    "playwright": True,
                    "playwright_page_methods": [("wait_for_load_state", {"state": "networkidle"})],
                    "playwright_context": "default",
                },
            )

        # Write one PDF per page
        filename = sanitize_filename_from_url(url)
        pdf_path = os.path.join(self.outdir, filename)
        payload = {
            "url": url,
            "title": title or "(No title)",
            # "fetched_at": datetime.datetime.utcnow().isoformat() + "Z",
            "meta": metas,
            "text": text,
            "outgoing_links": links,
        }
        try:
            make_pdf(pdf_path, payload)
            self.logger.info(f"Wrote PDF: {pdf_path}")
        except Exception as e:
            self.logger.error(f"Failed to write PDF for {url}: {e}")

# ---------------------------
# Runner
# ---------------------------
configure_logging()

async def crawl_to_pdfs(start_url: str, depth: int, outdir: str):
    """
    Run a single crawl with the given depth limit and PDF output directory.
    """
    allowed = same_site_allowed_domains(start_url)

    runner = CrawlerRunner(settings={
        "DEPTH_LIMIT": depth,
        # reactor set via env & install above
        "DOWNLOAD_HANDLERS": {
            "http": "scrapy_playwright.handler.ScrapyPlaywrightDownloadHandler",
            "https": "scrapy_playwright.handler.ScrapyPlaywrightDownloadHandler",
        },
        "PLAYWRIGHT_BROWSER_TYPE": "chromium",
        "PLAYWRIGHT_DEFAULT_NAVIGATION_TIMEOUT": 60000,
        "PLAYWRIGHT_LAUNCH_OPTIONS": {"headless": True},

        # Mirror spider custom settings relevant to scheduler/priority
        "DEPTH_PRIORITY": 1,
        "SCHEDULER_DISK_QUEUE": "scrapy.squeues.PickleFifoDiskQueue",
        "SCHEDULER_MEMORY_QUEUE": "scrapy.squeues.FifoMemoryQueue",
    })

    d = runner.crawl(
        SiteToPDFSpider,
        start_url=start_url,
        outdir=outdir,
        allowed_domains=allowed,
    )

    loop = asyncio.get_running_loop()
    await d.asFuture(loop)
    return True

# ---------------------------
# FastAPI endpoints
# ---------------------------
@app.post("/scrape")
async def scrape(req: CrawlRequest):
    workdir = tempfile.mkdtemp(prefix="scrape_pdfs_")
    outdir = os.path.join(workdir, "pdfs")
    os.makedirs(outdir, exist_ok=True)

    start_url = str(req.url)

    try:
        await crawl_to_pdfs(start_url, req.depth, outdir)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Crawl failed: {e}")

    pdf_files = [f for f in os.listdir(outdir) if f.lower().endswith(".pdf")]
    if not pdf_files:
        raise HTTPException(
            status_code=504,
            detail="Fetch timed out or was blocked before any page could be saved."
        )

    zip_path = os.path.join(workdir, "result.zip")
    with zipfile.ZipFile(zip_path, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name in pdf_files:
            zf.write(os.path.join(outdir, name), arcname=name)

    return FileResponse(zip_path, media_type="application/zip", filename="scraped_pdfs.zip")
