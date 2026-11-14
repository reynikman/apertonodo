"""MusicBrainz asks for a real contact in the User-Agent and answers 403 without one.

Every client that goes to MusicBrainz takes it from MUSICBRAINZ_CONTACT; empty means
the project page (FT-895: the owner's domain left the code, the contact must not).
"""

import asyncio

import pytest

from app.images import images_from_env
from app.lastfm import lastfm_from_env
from app.musicbrainz import DEFAULT_CONTACT, http_from_env


def catalog_agent(env):
    http = http_from_env(env)
    agent = http._client.headers["User-Agent"]
    asyncio.run(http.aclose())
    return agent


def images_agent(env, tmp_path):
    images = images_from_env({"IMAGE_DIR": str(tmp_path), **env}, "postgresql://unused")
    with images._client() as client:
        return client.headers["User-Agent"]


def lastfm_agent(env):
    lastfm = lastfm_from_env({"LASTFM_API_KEY": "k", **env}, "postgresql://unused")
    with lastfm.mb_client() as client:
        return client.headers["User-Agent"]


@pytest.fixture(params=["catalog", "images", "lastfm"])
def agent_of(request, tmp_path):
    return {
        "catalog": catalog_agent,
        "images": lambda env: images_agent(env, tmp_path),
        "lastfm": lastfm_agent,
    }[request.param]


def test_contact_from_the_environment_goes_into_the_user_agent(agent_of):
    assert "( admin@example.org )" in agent_of({"MUSICBRAINZ_CONTACT": " admin@example.org "})


@pytest.mark.parametrize("env", [{}, {"MUSICBRAINZ_CONTACT": "  "}])
def test_without_a_contact_the_project_page_is_sent(agent_of, env):
    assert f"( {DEFAULT_CONTACT} )" in agent_of(env)


def test_the_default_contact_is_reachable_not_a_bare_name():
    assert DEFAULT_CONTACT.startswith("https://")
