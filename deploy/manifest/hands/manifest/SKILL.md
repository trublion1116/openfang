---
name: manifest-hand-skill
version: "1.0.0"
description: "File upload to S3 via MCP OBS S3 server"
runtime: prompt_only
---

# Manifest Hand Skill

## File Attachment Format

When a user uploads a file, you receive:
```
[FILE_ATTACHMENT] filename="example.xlsx" content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" size="245.3KB" path="/tmp/openfang_uploads/abcd-1234-..."
```

Extract `path` and pass it to the MCP upload tool as `file_path`.

## MCP Tool Reference

MCP server name in config: `obs-s3` → normalized: `obs_s3` → tool prefix: `mcp_obs_s3_`

### mcp_obs_s3_s3_upload
- **Required**: `file_path` (string) — absolute local path
- **Optional**: `key` (string) — S3 object key, auto-generated if omitted
- **Optional**: `content_type` (string) — MIME type, auto-detected if omitted
- **Returns**: `{ success, key, url, size_bytes }`

The upload directory `/tmp/openfang_uploads/` is shared between OpenFang and MCP containers via Docker volume, so the MCP server can read files placed there by OpenFang.
