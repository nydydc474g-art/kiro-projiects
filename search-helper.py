#!/usr/bin/env python3
"""Read-only search and reader helper for the sandboxed agent."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable

DEFAULT_TIMEOUT = 20
DEFAULT_MAX_RESULTS = 5
MAX_RESULTS_LIMIT = 10
USER_AGENT = "search-helper/1.0 (+sandboxed-agent)"
JINA_USER_AGENT = "curl/8.0"
MAX_SNIPPET_CHARS = 800
MAX_CONTENT_CHARS = 2000


class HelperError(Exception):
    """Expected helper failure that is safe to expose."""

    def __init__(
        self,
        error_type: str,
        message: str,
        *,
        provider: str | None = None,
        status: int | None = None,
    ) -> None:
        super().__init__(message)
        self.error_type = error_type
        self.message = message
        self.provider = provider
        self.status = status


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def source_domain(url: str | None) -> str | None:
    if not url:
        return None
    return urllib.parse.urlparse(url).netloc or None


def clamp_max_results(value: int) -> int:
    if value < 1 or value > MAX_RESULTS_LIMIT:
        raise HelperError("invalid_argument", f"--max-results must be between 1 and {MAX_RESULTS_LIMIT}")
    return value


def require_key(env_name: str, provider: str) -> str:
    value = os.getenv(env_name)
    if not value:
        raise HelperError("missing_api_key", f"{env_name} is not set", provider=provider)
    return value


def request_json(
    provider: str,
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    payload: dict[str, Any] | None = None,
    timeout: int = DEFAULT_TIMEOUT,
) -> dict[str, Any]:
    body = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        url,
        data=body,
        headers={"User-Agent": USER_AGENT, **(headers or {})},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        raise HelperError("http_error", "request failed", provider=provider, status=exc.code) from exc
    except urllib.error.URLError as exc:
        raise HelperError("network_error", "request failed", provider=provider) from exc
    except json.JSONDecodeError as exc:
        raise HelperError("invalid_response", "response was not valid JSON", provider=provider) from exc


def normalized_result(
    *,
    title: str | None,
    url: str | None,
    snippet: str | None = None,
    content: str | None = None,
    published_date: str | None = None,
    score: float | int | None = None,
    provider_rank: int | None = None,
    include_content: bool = False,
) -> dict[str, Any]:
    result_url = url or ""
    path = urllib.parse.urlparse(result_url).path.lower()
    is_pdf = path.endswith(".pdf")
    return {
        "title": title,
        "url": url,
        "source_domain": source_domain(url),
        "source_type": "pdf" if is_pdf else ("html" if url else "unknown"),
        "is_pdf": is_pdf,
        "provider_rank": provider_rank,
        "snippet": truncate_text(snippet, MAX_SNIPPET_CHARS),
        "content": truncate_text(content, MAX_CONTENT_CHARS) if include_content else None,
        "published_date": published_date,
        "score": score,
    }


def truncate_text(value: str | None, limit: int) -> str | None:
    if value is None or len(value) <= limit:
        return value
    return value[: limit - 1] + "…"


def constrained_query(query: str, site: str | None, filetype: str | None) -> str:
    parts = [query]
    if site:
        parts.append(f"site:{site}")
    if filetype:
        parts.append(f"filetype:{filetype}")
    return " ".join(parts)


def tavily_search(
    query: str,
    max_results: int,
    locale: str,
    *,
    site: str | None = None,
    filetype: str | None = None,
    include_content: bool = False,
) -> list[dict[str, Any]]:
    key = require_key("TAVILY_API_KEY", "tavily")
    payload: dict[str, Any] = {
        "query": constrained_query(query, site, filetype),
        "max_results": max_results,
        "search_depth": "basic",
    }
    if locale == "zh-CN":
        payload["country"] = "china"
    data = request_json(
        "tavily",
        "POST",
        "https://api.tavily.com/search",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        payload=payload,
    )
    return [
        normalized_result(
            title=item.get("title"),
            url=item.get("url"),
            snippet=item.get("content"),
            content=item.get("content"),
            published_date=item.get("published_date"),
            score=item.get("score"),
            provider_rank=index,
            include_content=include_content,
        )
        for index, item in enumerate(data.get("results", []), start=1)
    ]


def brave_search(
    query: str,
    max_results: int,
    locale: str,
    *,
    site: str | None = None,
    filetype: str | None = None,
    include_content: bool = False,
) -> list[dict[str, Any]]:
    del include_content
    key = require_key("BRAVE_SEARCH_API_KEY", "brave")
    params: dict[str, str] = {"q": constrained_query(query, site, filetype), "count": str(max_results)}
    if locale == "zh-CN":
        params.update({"country": "CN", "search_lang": "zh-hans"})
    elif locale == "en":
        params.update({"country": "US", "search_lang": "en"})
    data = request_json(
        "brave",
        "GET",
        "https://api.search.brave.com/res/v1/web/search?" + urllib.parse.urlencode(params),
        headers={"Accept": "application/json", "X-Subscription-Token": key},
    )
    return [
        normalized_result(
            title=item.get("title"),
            url=item.get("url"),
            snippet=item.get("description"),
            published_date=item.get("age"),
            provider_rank=index,
        )
        for index, item in enumerate(data.get("web", {}).get("results", []), start=1)
    ]


def exa_search(
    query: str,
    max_results: int,
    locale: str,
    *,
    site: str | None = None,
    filetype: str | None = None,
    include_content: bool = False,
) -> list[dict[str, Any]]:
    del locale
    del include_content
    key = require_key("EXA_API_KEY", "exa")
    payload: dict[str, Any] = {
        "query": constrained_query(query, None, filetype),
        "numResults": max_results,
    }
    if site:
        payload["includeDomains"] = [site]
    data = request_json(
        "exa",
        "POST",
        "https://api.exa.ai/search",
        headers={"x-api-key": key, "Content-Type": "application/json"},
        payload=payload,
    )
    return [
        normalized_result(
            title=item.get("title"),
            url=item.get("url"),
            snippet=item.get("text"),
            published_date=item.get("publishedDate"),
            score=item.get("score"),
            provider_rank=index,
        )
        for index, item in enumerate(data.get("results", []), start=1)
    ]


def serper_search(
    query: str,
    max_results: int,
    locale: str,
    *,
    site: str | None = None,
    filetype: str | None = None,
    include_content: bool = False,
) -> list[dict[str, Any]]:
    del include_content
    key = require_key("SERPER_API_KEY", "serper")
    payload: dict[str, Any] = {"q": constrained_query(query, site, filetype), "num": max_results}
    if locale == "zh-CN":
        payload.update({"gl": "cn", "hl": "zh-cn"})
    data = request_json(
        "serper",
        "POST",
        "https://google.serper.dev/search",
        headers={"X-API-KEY": key, "Content-Type": "application/json"},
        payload=payload,
    )
    return [
        normalized_result(
            title=item.get("title"),
            url=item.get("link"),
            snippet=item.get("snippet"),
            published_date=item.get("date"),
            score=item.get("position"),
            provider_rank=index,
        )
        for index, item in enumerate(data.get("organic", []), start=1)
    ]


SEARCHERS: dict[str, Callable[..., list[dict[str, Any]]]] = {
    "tavily": tavily_search,
    "brave": brave_search,
    "exa": exa_search,
    "serper": serper_search,
}


def command_search(args: argparse.Namespace) -> dict[str, Any]:
    max_results = clamp_max_results(args.max_results)
    results = SEARCHERS[args.provider](
        args.query,
        max_results,
        args.locale,
        site=args.site,
        filetype=args.filetype,
        include_content=args.include_content,
    )
    return {
        "ok": True,
        "command": "search",
        "provider": args.provider,
        "query": args.query,
        "locale": args.locale,
        "site": args.site,
        "filetype": args.filetype,
        "include_content": args.include_content,
        "result_count": len(results),
        "results": results,
        "retrieved_at": utc_now(),
    }


def reader_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HelperError("invalid_argument", "--url must be an absolute http(s) URL")
    return "https://r.jina.ai/" + url


def command_read(args: argparse.Namespace) -> dict[str, Any]:
    url = args.url
    request = urllib.request.Request(
        reader_url(url),
        headers={"User-Agent": JINA_USER_AGENT, "Accept": "text/plain"},
    )
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            text = response.read(args.max_bytes + 1).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raise HelperError("http_error", "reader request failed", provider="jina", status=exc.code) from exc
    except urllib.error.URLError as exc:
        raise HelperError("network_error", "reader request failed", provider="jina") from exc

    truncated = len(text) > args.max_bytes
    if truncated:
        text = text[: args.max_bytes]
    title = None
    for line in text.splitlines():
        if line.startswith("Title: "):
            title = line.removeprefix("Title: ").strip() or None
            break
    return {
        "ok": True,
        "command": "read",
        "reader": "jina",
        "url": url,
        "source_domain": source_domain(url),
        "title": title,
        "text": text,
        "truncated": truncated,
        "retrieved_at": utc_now(),
    }


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Read-only search helper")
    subcommands = root.add_subparsers(dest="command", required=True)

    search = subcommands.add_parser("search", help="search using a configured provider")
    search.add_argument("--provider", choices=sorted(SEARCHERS), default="tavily")
    search.add_argument("--query", required=True)
    search.add_argument("--max-results", type=int, default=DEFAULT_MAX_RESULTS)
    search.add_argument("--locale", choices=("auto", "en", "zh-CN"), default="auto")
    search.add_argument("--site")
    search.add_argument("--filetype", choices=("pdf",))
    search.add_argument("--include-content", action="store_true")
    search.set_defaults(func=command_search)

    read = subcommands.add_parser("read", help="read a URL through r.jina.ai")
    read.add_argument("--url", required=True)
    read.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    read.add_argument("--max-bytes", type=int, default=200_000)
    read.set_defaults(func=command_read)
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        result = args.func(args)
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0
    except HelperError as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "command": getattr(args, "command", None),
                    "provider": exc.provider,
                    "error_type": exc.error_type,
                    "status": exc.status,
                    "error": exc.message,
                    "retrieved_at": utc_now(),
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
