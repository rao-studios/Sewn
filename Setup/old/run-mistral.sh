#!/bin/bash

# .dist/Build/Products/Release/seer-server --mistral --embedding-model mlx-community/Qwen3-Embedding-8B-4bit-DWQ --host 127.0.0.1 --port 8080

.././.build/release/seer-server --mistral --host 0.0.0.0 --port 8080
