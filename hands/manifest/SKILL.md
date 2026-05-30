---
name: manifest-hand-skill
version: "1.0.0"
description: "File-to-manifest pipeline knowledge — S3 upload, A2A delegation, manifest download"
runtime: prompt_only
---

# Manifest Hand Skill

## Overview

Manifest Hand is a file-to-manifest pipeline that:
1. Receives file uploads from the user (no multimodal processing)
2. Uploads files to S3 via MCP tools
3. Sends the S3 URL to an external manifest agent via A2A protocol
4. Downloads the generated manifest from S3
5. Provides a download link in the chat interface

## Supported File Types

| Category | Formats | MIME Types |
|----------|---------|-----------|
| Images | PNG, JPEG, GIF, WebP | `image/*` |
| Text | TXT, CSV, MD, JSON | `text/*` |
| Office | XLSX, DOCX, PPTX, XLS, DOC | `application/vnd.openxmlformats-officedocument.*` |
| Archives | ZIP, GZIP | `application/zip`, `application/gzip` |
| Other | PDF | `application/pdf` |

## File Attachment Format

When a user uploads a file, you receive a structured text block:
```
[FILE_ATTACHMENT] filename="example.xlsx" content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" size="245.3KB" path="/tmp/openfang_uploads/abcd-1234-ef56-..."
```

Parse this to extract:
- `filename` — original file name (use as manifest name prefix)
- `content_type` — MIME type (for logging)
- `size` — file size (for logging)
- `path` — local file path (pass to MCP upload tool)

## MCP Tool Interface

### S3 Upload Tool
```
Tool: {s3_upload_tool} (default: mcp_s3_upload)
Input: { "path": "/tmp/openfang_uploads/...", "filename": "report.xlsx" }
Output: { "url": "https://s3.amazonaws.com/bucket/...", "key": "..." }
```

### S3 Download Tool
```
Tool: {s3_download_tool} (default: mcp_s3_download)
Input: { "url": "https://s3.amazonaws.com/bucket/manifest.json", "output_path": "output/manifest_report.json" }
Output: { "file_path": "/workspace/output/manifest_report.json", "size": 1024 }
```

## A2A Protocol

### Sending to Manifest Agent
```
Tool: a2a_send
Input: {
  "agent_name": "manifest-agent",  // or agent_url for direct URL
  "message": "Please process file at S3 URL: https://s3.amazonaws.com/bucket/uploads/report.xlsx"
}
Output: A2aTask with response containing manifest S3 URL
```

### Expected External Agent Response
The external manifest agent returns a response containing:
- The manifest S3 URL
- Processing status (success/failure)
- Optional metadata about the manifest

## Output File Naming

Manifest files are saved to `output/` directory with naming convention:
- `manifest_<original_filename_without_ext>.json`
- Example: `report.xlsx` → `output/manifest_report.json`
- Example: `data.zip` → `output/manifest_data.json`

This ensures uniqueness — the original filename is preserved as prefix.

## Download URL Format

After saving the manifest, provide the user with:
```
/api/agents/{agent_id}/output/manifest_<name>.json
```

Users can click this link to download the manifest file directly from the chat.
