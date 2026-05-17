# kiro-projiects

Zero-Trust local AI sandbox: Claude Code agent + Squid egress proxy + LiteLLM
+ audit collector + Telegram notifier + ops-watcher.

## Repository layout (Dockerfile identity guide)

```
kiro-projiects/
├── Dockerfile                ← AGENT image     (node:20-slim + claude-code)
├── docker-compose.yml
│
├── notifier/
│   ├── Dockerfile            ← NOTIFIER image  (python + telegram)
│   └── notifier.py
│
├── collector/
│   ├── Dockerfile            ← COLLECTOR image (python + audit ingest)
│   └── collector.py
│
├── proxy/
│   ├── squid.conf
│   └── allowed_domains.txt
│
├── config/
│   └── litellm_config.yaml
│
└── scripts/
    ├── search-helper.py      ← copied into agent image at /usr/local/bin/search-helper
    └── ops/                  ← ops-watcher (host-side proposal review pipeline)
        ├── init-snapshot.sh
        ├── ops-helper.sh
        ├── ops-watcher.sh
        ├── ops-baseline.json
        └── README.md
```

Each Dockerfile carries a banner comment naming the service it builds, so
agents (and humans) cannot confuse them when grepping the tree.

## docker-compose service → Dockerfile mapping

| Service     | build.context | Dockerfile path        |
|-------------|---------------|------------------------|
| agent       | `.`           | `./Dockerfile`         |
| notifier    | `./notifier`  | `./notifier/Dockerfile`|
| collector   | `./collector` | `./collector/Dockerfile`|
| squid       | (image)       | `ubuntu/squid` upstream|
| litellm     | (image)       | `ghcr.io/berriai/litellm:main-latest` |
| cliproxyapi | (image)       | `eceasy/cli-proxy-api:latest` |

## Ops-watcher

Host-side static review of agent-submitted change proposals.
See `scripts/ops/README.md` and `OPS-WATCHER-DESIGN.md`.
