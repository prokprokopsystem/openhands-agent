"""Shared Mem0 configuration for the M2 prototype.

Deliberately explicit: Mem0 defaults the LLM and embedder to OpenAI, which this
prototype must never use. The LLM is pinned to DeepSeek with a placeholder key
so that any accidental infer=True call fails loudly instead of silently
reaching an external OpenAI endpoint.
"""

import os
from pathlib import Path

os.environ.setdefault("MEM0_TELEMETRY", "False")

from mem0 import Memory  # noqa: E402
from mem0.configs.base import MemoryConfig  # noqa: E402
from mem0.embeddings.configs import EmbedderConfig  # noqa: E402
from mem0.llms.configs import LlmConfig  # noqa: E402
from mem0.vector_stores.configs import VectorStoreConfig  # noqa: E402

ROOT = Path("/projects/memory-pilot")
STORE = ROOT / "store"
COLLECTION = "m2_memories"
EMBED_MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
EMBED_DIMS = 384

# fastembed defaults to <tmp>/fastembed_cache, which is ephemeral in this
# container. Pin the model cache inside the persistent store instead.
MODELS = STORE / "models"
MODELS.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("FASTEMBED_CACHE_PATH", str(MODELS))

# Placeholder, intentionally invalid: no DeepSeek/OpenAI call may happen on M2.
LLM_API_KEY = "M2-LOCAL-ONLY-NO-LLM-CALLS"


def config() -> MemoryConfig:
    return MemoryConfig(
        vector_store=VectorStoreConfig(
            provider="qdrant",
            config={
                "path": str(STORE / "qdrant_db"),
                "collection_name": COLLECTION,
                "embedding_model_dims": EMBED_DIMS,
                "on_disk": True,
            },
        ),
        embedder=EmbedderConfig(
            provider="fastembed",
            config={"model": EMBED_MODEL, "embedding_dims": EMBED_DIMS},
        ),
        llm=LlmConfig(
            provider="deepseek",
            config={"api_key": LLM_API_KEY, "model": "deepseek-chat"},
        ),
        history_db_path=str(STORE / "history.db"),
    )


def memory() -> Memory:
    return Memory(config=config())
