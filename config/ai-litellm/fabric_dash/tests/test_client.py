import json
from fabric_dash.client import FabricClient

def fake(out_by_cmd):
    def run(argv):
        key = " ".join(argv)
        if key in out_by_cmd:
            return (0, out_by_cmd[key])
        return (1, "")
    return run

def test_proxy_status_parses():
    c = FabricClient(runner=fake({
        "ai-litellm proxy status --json": json.dumps({"health": "ok", "configCurrency": "stale"})
    }))
    s = c.proxy_status()
    assert s["health"] == "ok"
    assert s["configCurrency"] == "stale"

def test_list_method_empty_on_failure():
    c = FabricClient(runner=fake({}))  # every cmd returns rc=1
    assert c.model_list() == []

def test_object_method_empty_on_invalid_json():
    c = FabricClient(runner=fake({"ai-litellm proxy status --json": "not json"}))
    assert c.proxy_status() == {}

def test_reasoning_allowed_reads():
    from fabric_dash.client import FabricClient
    seen = []
    def run(argv):
        seen.append(argv)
        if argv[:4] == ["ai-litellm", "model", "reasoning", "allowed"]:
            return (0, '["low","high","xhigh"]')
        if argv[:4] == ["ai-litellm", "harness", "reasoning", "allowed"]:
            return (0, '["auto","high","max"]')
        return (1, "")
    c = FabricClient(runner=run)
    assert c.model_reasoning_allowed("GLM-5.2") == ["low", "high", "xhigh"]
    assert c.harness_reasoning_allowed("claude") == ["auto", "high", "max"]
    assert ["ai-litellm", "model", "reasoning", "allowed", "GLM-5.2", "--json"] in seen
    # failure → empty list, never raises
    assert FabricClient(runner=lambda a: (1, "")).model_reasoning_allowed("x") == []

def test_harness_aliases_read():
    from fabric_dash.client import FabricClient
    seen = []
    def run(argv):
        seen.append(argv)
        if argv[:4] == ["ai-litellm", "harness", "alias", "get"]:
            return (0, '[{"tier":"fable","model":"GLM-5.2-openrouter","direct":"z-ai/glm-5.2","label":"GLM-5.2 (openrouter)"}]')
        return (1, "")
    c = FabricClient(runner=run)
    rows = c.harness_aliases("claude")
    assert rows[0]["tier"] == "fable" and rows[0]["model"] == "GLM-5.2-openrouter"
    assert ["ai-litellm", "harness", "alias", "get", "claude", "--json"] in seen
    assert FabricClient(runner=lambda a: (1, "")).harness_aliases("claude") == []

def test_codex_facades_read():
    from fabric_dash.client import FabricClient
    seen = []
    def run(argv):
        seen.append(argv)
        if argv[:3] == ["ai-litellm", "codex", "facade"]:
            return (0, '[{"facade":"gpt-5.5","model":"openrouter/z-ai/glm-5.2","info":"*glm52"}]')
        return (1, "")
    c = FabricClient(runner=run)
    rows = c.codex_facades()
    assert rows[0]["facade"] == "gpt-5.5"
    assert ["ai-litellm", "codex", "facade", "get", "--json"] in seen
    assert FabricClient(runner=lambda a: (1, "")).codex_facades() == []
