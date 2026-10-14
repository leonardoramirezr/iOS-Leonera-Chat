#!/usr/bin/env python3
"""The GitHub Pages site the builds are installed from. Only the standard library.

Commands:
  folder ...   Writes manifest.plist, index.html and build.json into a build's folder, which already
               holds the IPA and the 57 and 512 px icons.
  index ...    Prunes the site (every version from main, the last N branch builds) and writes its home
               page, listing every build, and .nojekyll.
"""

import argparse
import datetime
import html
import json
import os
import plistlib
import shutil
import sys
import urllib.parse

STYLE = """
:root { color-scheme: light dark; --accent: #6547F2; --bg: #F2F2F7; --card: #FFFFFF; --text: #1C1C1E; --muted: #6E6E73; --line: #E5E5EA; }
@media (prefers-color-scheme: dark) { :root { --accent: #907EFF; --bg: #000000; --card: #1C1C1E; --text: #F2F2F7; --muted: #98989F; --line: #38383A; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 17px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
main { max-width: 560px; margin: 0 auto; padding: 32px 16px 48px; }
header { text-align: center; margin-bottom: 28px; }
header img { width: 96px; height: 96px; border-radius: 22px; box-shadow: 0 8px 24px rgba(0,0,0,.18); }
h1 { font-size: 28px; margin: 16px 0 4px; letter-spacing: -.02em; }
h2 { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 28px 16px 8px; }
.muted { color: var(--muted); }
.small { font-size: 14px; }
.button { display: block; text-align: center; background: var(--accent); color: #fff; text-decoration: none; font-weight: 600; padding: 15px 20px; border-radius: 14px; margin: 20px 0 8px; }
.button.small { display: inline-block; padding: 7px 16px; margin: 0; border-radius: 999px; font-size: 15px; }
.card { background: var(--card); border-radius: 14px; overflow: hidden; }
.row { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-top: 1px solid var(--line); }
.row:first-child { border-top: 0; }
.row .text { flex: 1; min-width: 0; }
.row .title { font-weight: 600; text-decoration: none; }
.row .detail { font-size: 14px; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row a.detail { text-decoration: none; }
dl { margin: 0; }
dl div { display: flex; justify-content: space-between; gap: 16px; padding: 11px 16px; border-top: 1px solid var(--line); }
dl div:first-child { border-top: 0; }
dt { color: var(--muted); }
dd { margin: 0; text-align: right; overflow-wrap: anywhere; }
a { color: var(--accent); }
p.note { font-size: 14px; color: var(--muted); margin: 12px 16px; }
"""


def page(title, body):
    return f"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{STYLE}</style>
</head>
<body>
<main>
{body}
</main>
</body>
</html>
"""


def install_url(manifest_url):
    return "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest_url, safe="")


def folder(args):
    base = args.base_url.rstrip("/") + "/"
    folder_url = base + urllib.parse.quote(args.tag) + "/"
    ipa_url = folder_url + urllib.parse.quote(args.ipa)
    manifest_url = folder_url + "manifest.plist"

    manifest = {
        "items": [
            {
                "assets": [
                    {"kind": "software-package", "url": ipa_url},
                    {"kind": "display-image", "url": folder_url + "icon-57.png"},
                    {"kind": "full-size-image", "url": folder_url + "icon-512.png"},
                ],
                "metadata": {
                    "bundle-identifier": args.bundle_id,
                    "bundle-version": args.version,
                    "kind": "software",
                    "title": args.title,
                },
            }
        ]
    }
    with open(os.path.join(args.dir, "manifest.plist"), "wb") as file:
        plistlib.dump(manifest, file)

    build = {
        "tag": args.tag,
        "channel": args.channel,
        "title": args.title,
        "version": args.version,
        "build": args.build,
        "branch": args.branch,
        "sha": args.sha,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "devices": args.devices,
        "bundle_id": args.bundle_id,
        "ipa": args.ipa,
        "ipa_url": ipa_url,
        "manifest_url": manifest_url,
        "install_url": install_url(manifest_url),
        "page_url": folder_url,
        "run_url": args.run_url,
        "repository_url": args.repository_url,
    }
    with open(os.path.join(args.dir, "build.json"), "w") as file:
        json.dump(build, file, indent=2)
        file.write("\n")

    with open(os.path.join(args.dir, "index.html"), "w") as file:
        file.write(build_page(build))

    json.dump(build, sys.stdout, indent=2)
    print()


def label(build):
    return f"{build['version']} ({build['build']})"


def build_page(build):
    e = html.escape
    channel = "Versión estable" if build["channel"] == "stable" else "Build de prueba"
    commit = build["sha"][:7]
    commit_link = (
        f'<a href="{e(build["repository_url"])}/commit/{e(build["sha"])}">{e(commit)}</a>'
        if build.get("repository_url") else e(commit)
    )
    run_link = f'<a href="{e(build["run_url"])}">Ver ejecución</a>' if build.get("run_url") else ""
    return page(
        f"{build['title']} {build['tag']}",
        f"""<header>
<img src="icon-512.png" alt="">
<h1>{e(build['title'])}</h1>
<div class="muted">{e(channel)} · {e(label(build))}</div>
</header>
<a class="button" href="{e(build['install_url'])}">Instalar en el iPhone</a>
<p class="note">Abre esta página en Safari en un iPhone registrado. Tras tocar «Instalar», la app aparece en la pantalla de inicio.</p>
<h2>Detalles</h2>
<div class="card"><dl>
<div><dt>Etiqueta</dt><dd>{e(build['tag'])}</dd></div>
<div><dt>Versión</dt><dd>{e(label(build))}</dd></div>
<div><dt>Rama</dt><dd>{e(build['branch'])}</dd></div>
<div><dt>Commit</dt><dd>{commit_link}</dd></div>
<div><dt>Fecha</dt><dd>{e(build['date'].replace('T', ' ').replace('Z', ' UTC'))}</dd></div>
<div><dt>Dispositivos en el perfil</dt><dd>{e(str(build['devices']))}</dd></div>
<div><dt>Identificador</dt><dd>{e(build['bundle_id'])}</dd></div>
</dl></div>
<p class="note"><a href="{e(build['ipa'])}">Descargar el IPA</a> · <a href="../">Todos los builds</a>{' · ' + run_link if run_link else ''}</p>
""",
    )


def read_builds(site):
    builds = []
    for name in sorted(os.listdir(site)):
        path = os.path.join(site, name, "build.json")
        if os.path.isfile(path):
            try:
                with open(path) as file:
                    build = json.load(file)
            except (OSError, ValueError):
                continue
            build["folder"] = name
            builds.append(build)
    return builds


def stable_key(build):
    try:
        return tuple(int(part) for part in build["version"].split("."))
    except (KeyError, ValueError):
        return (0,)


def branch_key(build):
    try:
        return (int(build.get("build", 0)), build.get("date", ""))
    except ValueError:
        return (0, build.get("date", ""))


def index(args):
    site = args.site
    builds = read_builds(site)
    stable = sorted((b for b in builds if b.get("channel") == "stable"), key=stable_key, reverse=True)
    branch = sorted((b for b in builds if b.get("channel") != "stable"), key=branch_key, reverse=True)

    # Every version from main stays; of the branch builds, only the latest ones.
    for build in branch[args.keep_branch_builds:]:
        shutil.rmtree(os.path.join(site, build["folder"]))
        print(f"Removed {build['folder']}")
    branch = branch[: args.keep_branch_builds]

    # Nothing but the build folders: the branch may have been created from the code.
    kept = {b["folder"] for b in stable + branch}
    for name in os.listdir(site):
        path = os.path.join(site, name)
        if name not in kept and name not in ("index.html", ".nojekyll"):
            if os.path.isdir(path):
                shutil.rmtree(path)
            else:
                os.remove(path)

    with open(os.path.join(site, ".nojekyll"), "w"):
        pass
    with open(os.path.join(site, "index.html"), "w") as file:
        file.write(home_page(stable, branch, args.title))
    print(f"{len(stable)} stable versions, {len(branch)} branch builds.")


def rows(builds):
    e = html.escape
    items = []
    for build in builds:
        date = build.get("date", "")[:10]
        detail = f"{build.get('branch', '')} · {build.get('sha', '')[:7]} · {date}"
        items.append(
            f"""<div class="row">
<div class="text"><a class="title" href="{e(build['folder'])}/">{e(build['tag'])}</a>
<div class="detail">{e(label(build))} · {e(detail)}</div></div>
<a class="button small" href="{e(build['install_url'])}">Instalar</a>
</div>"""
        )
    return "\n".join(items)


def home_page(stable, branch, title):
    e = html.escape
    icon = f"{e(stable[0]['folder'])}/icon-512.png" if stable else (f"{e(branch[0]['folder'])}/icon-512.png" if branch else "")
    latest = (
        f"""<a class="button" href="{e(stable[0]['install_url'])}">Instalar la última versión estable ({e(stable[0]['tag'])})</a>"""
        if stable
        else '<p class="note">Aún no hay versiones estables: se publican con cada push a main.</p>'
    )
    sections = ""
    if stable:
        sections += f'<h2>Versiones estables</h2>\n<div class="card">\n{rows(stable)}\n</div>\n'
    if branch:
        sections += f'<h2>Builds de ramas</h2>\n<div class="card">\n{rows(branch)}\n</div>\n'
    return page(
        title,
        f"""<header>
{f'<img src="{icon}" alt="">' if icon else ''}
<h1>{e(title)}</h1>
<div class="muted">Builds Ad Hoc para los iPhone registrados</div>
</header>
{latest}
<p class="note">Abre esta página en Safari en un iPhone cuyo UDID esté registrado en la cuenta de desarrollador.</p>
{sections}""",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    f = commands.add_parser("folder")
    f.add_argument("--dir", required=True)
    f.add_argument("--tag", required=True)
    f.add_argument("--channel", choices=["stable", "prerelease"], required=True)
    f.add_argument("--title", required=True)
    f.add_argument("--version", required=True)
    f.add_argument("--build", required=True)
    f.add_argument("--branch", required=True)
    f.add_argument("--sha", required=True)
    f.add_argument("--bundle-id", required=True)
    f.add_argument("--ipa", required=True)
    f.add_argument("--devices", type=int, required=True)
    f.add_argument("--base-url", required=True)
    f.add_argument("--run-url", default="")
    f.add_argument("--repository-url", default="")

    i = commands.add_parser("index")
    i.add_argument("--site", required=True)
    i.add_argument("--title", required=True)
    i.add_argument("--keep-branch-builds", type=int, default=20)

    args = parser.parse_args()
    if args.command == "folder":
        folder(args)
    else:
        index(args)


if __name__ == "__main__":
    main()
