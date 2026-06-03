---
name: manifest-pipeline-skill
version: "1.0.0"
description: "File processing pipeline — S3 upload, A2A delegation, download link"
runtime: prompt_only
---

# Manifest Pipeline Hand Skill

## Overview

Manifest Pipeline Hand is a file processing pipeline that:
1. Receives file uploads from the user
2. Uploads files to S3 via MCP tools
3. Sends the S3 URL to an external manifest agent via A2A protocol
4. Extracts the download link from the A2A response
5. Returns a clickable markdown download link in the chat interface

## File Attachment Format

When a user uploads a file, you receive a structured text block:
```
[FILE_ATTACHMENT] filename="example.xlsx" content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" size="245.3KB" path="/tmp/openfang_uploads/abcd-1234-ef56-..."
```

Parse this to extract:
- `filename` — original file name
- `content_type` — MIME type (for logging)
- `size` — file size (for logging)
- `path` — local file path (pass to MCP upload tool)

## MCP Tool Interface

### S3 Upload Tool
```
Tool: mcp_obs_s3_s3_upload
Input: { "file_path": "/tmp/openfang_uploads/..." }
Optional: { "key": "custom-s3-key", "content_type": "application/..." }
Output: { "success": true, "key": "...", "url": "...", "size_bytes": ... }
```

## A2A Protocol

### Discovering External Agents
```
Tool: a2a_discover
Input: {}
Output: List of available agents with names and URLs
```

### Sending to Manifest Agent
```
Tool: a2a_send
Input: {
  "agent_name": "manifest-agent",   // name from config.toml [[a2a.external_agents]]
  "message": "Process file at S3 URL: <s3_url>. Filename: <filename>"
}
```

Or with direct URL:
```
Input: {
  "agent_url": "https://your-manifest-agent.example.com",
  "message": "Process file at S3 URL: <s3_url>. Filename: <filename>"
}
```

### Expected External Agent Response
The external manifest agent returns a response containing:
- A download URL (typically S3 presigned URL) pointing to the processed result
- Processing status (success/failure)
- Optional metadata about the processing result

## Download Link Format

After receiving the download URL from the external agent, present it to the user as:
```markdown
[点击下载 manifest](https://s3.example.com/bucket/manifest_result.json?...)
```

The frontend (marked.js) automatically renders markdown links as clickable hyperlinks in the chat interface.

## Configuration

The external agent URL is configured in `config.toml`:
```toml
[a2a]
enabled = true

[[a2a.external_agents]]
name = "manifest-agent"
url = "https://your-manifest-agent.example.com"
```
