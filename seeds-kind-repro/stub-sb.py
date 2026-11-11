import sys

sys.path.insert(0, "/app")
import uvicorn
from app.providers import service_bus as sb


async def _noop(*_a, **_k):
    return None


sb.service_bus_provider.initialize = _noop
uvicorn.run("app.main:app", host="0.0.0.0", port=4000)
