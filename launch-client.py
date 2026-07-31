#!/usr/bin/env python3
"""Manage multiple WoW bot Wine processes with auto-restart on crash."""

import argparse
import concurrent.futures
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass

MAX_BOTS = 25
KILL_TIMEOUT = 5
DEFAULT_STAGGER = 0.5
DEFAULT_FPS = 15
DXVK_SETUP_PARALLELISM = 3
DEFAULT_SWAY_SCREEN_WIDTH = 3440
DEFAULT_SWAY_SCREEN_HEIGHT = 1440
DEFAULT_SWAY_Y_OFFSET = 1080
DEFAULT_SWAY_WORKSPACE = 1
DEFAULT_SWAY_CONFIG_PATH = ".sway"
MAX_SINGLE_BOT_WINDOW_PIXELS = 1920 * 1080
TARGET_AUTO_ASPECT_NUM = 16
TARGET_AUTO_ASPECT_DEN = 9
AUTO_SCORE_EPSILON = 1e-6


@dataclass(frozen=True)
class SwayLayoutConfig:
    screen_width: int
    screen_height: int
    y_offset: int
    workspace_start: int
    config_path: str


@dataclass(frozen=True)
class LaunchConfig:
    wow_exe: str
    expansion: str
    clients_dir: str
    stagger: float
    mastermind_host: str
    fps: int
    max_workspaces: int
    sway: SwayLayoutConfig


@dataclass(frozen=True)
class SwayGrid:
    cols: int
    rows_per_workspace: int
    bots_per_workspace: int
    x_margin: int
    y_margin: int


@dataclass(frozen=True)
class SwayPlacement:
    workspace: int
    x: int
    y: int


@dataclass(frozen=True)
class GridCandidate:
    cols: int
    rows: int
    capacity: int


@dataclass(frozen=True)
class ResolutionCandidate:
    width: int
    height: int
    area: int
    aspect_quality: float
    score: float


@dataclass(frozen=True)
class LayoutScore:
    resolution_score: float
    area: int
    width: int


@dataclass(frozen=True)
class LayoutCandidate:
    grid: GridCandidate
    resolution: ResolutionCandidate
    bots_per_workspace: int


# ── helpers ───────────────────────────────────────────────────────────────────


def die(msg: str) -> None:
    print(f"Erreur : {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg: str) -> None:
    print(msg, flush=True)


def prefix_path(bot_id: int) -> str:
    return os.path.expanduser(f"~/.wine-wow-bot{bot_id}")


def template_prefix_path() -> str:
    return os.path.expanduser("~/.wine-wow-template")


def prefix_active(bot_id: int) -> bool:
    """True if a wineserver is running for this prefix (server-* dir exists)."""
    import glob

    return bool(glob.glob(os.path.join(prefix_path(bot_id), "server-*")))


def kill_prefix(bot_id: int) -> None:
    env = {**os.environ, "WINEPREFIX": prefix_path(bot_id)}
    subprocess.run(["wineserver", "-k"], env=env, stderr=subprocess.DEVNULL)


def wait_dead(bot_ids: list[int], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while any(prefix_active(i) for i in bot_ids):
        if time.monotonic() >= deadline:
            print(
                f"Avertissement : certains bots encore vivants après {timeout:.0f}s — on continue.",
                file=sys.stderr,
            )
            return
        time.sleep(0.5)


def require_cmd(name: str) -> None:
    if not shutil.which(name):
        die(f"'{name}' introuvable dans PATH")


def parse_fps(value: str) -> int:
    try:
        fps = int(value)
    except ValueError:
        die(f"fps invalide '{value}' (attendu entier >= 0)")

    if fps < 0:
        die(f"fps invalide '{value}' (attendu entier >= 0)")

    return fps


def parse_stagger(value: str) -> float:
    try:
        stagger = float(value)
    except ValueError:
        die(f"WOW_STAGGER invalide '{value}' (attendu nombre >= 0)")

    if stagger < 0:
        die(f"WOW_STAGGER invalide '{value}' (attendu nombre >= 0)")

    return stagger


def parse_int(value: str, name: str, *, minimum: int = 0) -> int:
    try:
        parsed = int(value)
    except ValueError:
        die(f"{name} invalide '{value}' (attendu entier >= {minimum})")

    if parsed < minimum:
        die(f"{name} invalide '{value}' (attendu entier >= {minimum})")

    return parsed


def parse_bot_selector(value: str) -> list[int]:
    bot_ids: set[int] = set()

    for chunk in value.split(","):
        raw = chunk.strip()
        if raw == "":
            die(f"sélecteur --bots invalide '{value}'")

        first_str, sep, last_str = raw.partition("-")
        if sep == "":
            bot_ids.add(parse_int(first_str, "--bots", minimum=1))
            continue

        first = parse_int(first_str, "--bots", minimum=1)
        last = parse_int(last_str, "--bots", minimum=1)
        if last < first:
            die(
                f"plage --bots invalide '{raw}' (attendu FIRST-LAST avec LAST >= FIRST)"
            )

        for bot_id in range(first, last + 1):
            bot_ids.add(bot_id)

    return sorted(bot_ids)


def format_bot_selector(bot_ids: list[int]) -> str:
    return ",".join(str(bot_id) for bot_id in bot_ids)


def format_resolution(width: int, height: int) -> str:
    return f"{width}x{height}"


def aspect_quality(width: int, height: int) -> float:
    aspect_a = width * TARGET_AUTO_ASPECT_DEN
    aspect_b = height * TARGET_AUTO_ASPECT_NUM
    return min(aspect_a, aspect_b) / max(aspect_a, aspect_b)


def iter_grid_candidates(
    *,
    bot_count: int,
    max_workspaces: int,
    screen_width: int,
    screen_height: int,
) -> list[GridCandidate]:
    candidates: list[GridCandidate] = []

    for cols in range(1, bot_count + 1):
        if screen_width // cols <= 0:
            continue

        for rows in range(1, bot_count + 1):
            if screen_height // rows <= 0:
                continue

            capacity = max_workspaces * cols * rows
            if capacity < bot_count:
                continue

            candidates.append(GridCandidate(cols=cols, rows=rows, capacity=capacity))

    return candidates


def best_resolution_for_cell(
    cell_width: int,
    cell_height: int,
    *,
    max_window_pixels: int | None,
    prefer_area_first: bool,
) -> ResolutionCandidate | None:
    best: ResolutionCandidate | None = None

    for width in range(1, cell_width + 1):
        if max_window_pixels is None:
            height = cell_height
        else:
            height = min(cell_height, max_window_pixels // width)
        area = width * height
        if area == 0:
            continue

        quality = aspect_quality(width, height)
        score = area * quality
        candidate = ResolutionCandidate(
            width=width,
            height=height,
            area=area,
            aspect_quality=quality,
            score=score,
        )
        if best is None:
            best = candidate
            continue

        if prefer_area_first:
            area_equal = candidate.area == best.area
            aspect_equal = (
                abs(candidate.aspect_quality - best.aspect_quality)
                <= AUTO_SCORE_EPSILON
            )
            if (
                candidate.area > best.area
                or (
                    area_equal
                    and candidate.aspect_quality
                    > best.aspect_quality + AUTO_SCORE_EPSILON
                )
                or (
                    area_equal
                    and aspect_equal
                    and candidate.width == cell_width
                    and best.width != cell_width
                )
                or (area_equal and aspect_equal and candidate.width > best.width)
            ):
                best = candidate
            continue

        score_equal = abs(candidate.score - best.score) <= AUTO_SCORE_EPSILON
        if (
            candidate.score > best.score + AUTO_SCORE_EPSILON
            or (score_equal and candidate.area > best.area)
            or (
                score_equal
                and candidate.area == best.area
                and candidate.width == cell_width
                and best.width != cell_width
            )
            or (
                score_equal
                and candidate.area == best.area
                and candidate.width > best.width
            )
        ):
            best = candidate

    return best


def workspace_count(bot_count: int, bots_per_workspace: int) -> int:
    return (bot_count + bots_per_workspace - 1) // bots_per_workspace


def layout_score(candidate: LayoutCandidate) -> LayoutScore:
    if candidate.bots_per_workspace <= 2:
        return LayoutScore(
            resolution_score=(
                float(candidate.resolution.area) + candidate.resolution.aspect_quality
            ),
            area=candidate.resolution.area,
            width=candidate.resolution.width,
        )

    return LayoutScore(
        resolution_score=candidate.resolution.score,
        area=candidate.resolution.area,
        width=candidate.resolution.width,
    )


def is_better_layout(candidate: LayoutCandidate, current: LayoutCandidate) -> bool:
    candidate_score = layout_score(candidate)
    current_score = layout_score(current)
    score_equal = (
        abs(candidate_score.resolution_score - current_score.resolution_score)
        <= AUTO_SCORE_EPSILON
    )

    return (
        candidate_score.resolution_score
        > current_score.resolution_score + AUTO_SCORE_EPSILON
        or (score_equal and candidate_score.area > current_score.area)
        or (
            score_equal
            and candidate_score.area == current_score.area
            and candidate_score.width > current_score.width
        )
    )


def auto_resolution_for_workspaces(
    *,
    bot_count: int,
    max_workspaces: int,
    screen_width: int,
    screen_height: int,
) -> tuple[int, int]:
    best_layout: LayoutCandidate | None = None

    for grid in iter_grid_candidates(
        bot_count=bot_count,
        max_workspaces=max_workspaces,
        screen_width=screen_width,
        screen_height=screen_height,
    ):
        cell_width = screen_width // grid.cols
        cell_height = screen_height // grid.rows
        grid_bots_per_workspace = grid.cols * grid.rows
        used_workspaces = workspace_count(bot_count, grid_bots_per_workspace)
        bots_per_workspace = (bot_count + used_workspaces - 1) // used_workspaces
        max_window_pixels = None
        if bots_per_workspace == 1:
            max_window_pixels = MAX_SINGLE_BOT_WINDOW_PIXELS
        resolution = best_resolution_for_cell(
            cell_width,
            cell_height,
            max_window_pixels=max_window_pixels,
            prefer_area_first=bots_per_workspace <= 2,
        )
        if resolution is None:
            continue

        candidate = LayoutCandidate(
            grid=grid,
            resolution=resolution,
            bots_per_workspace=bots_per_workspace,
        )
        if best_layout is None:
            best_layout = candidate
            continue

        if is_better_layout(candidate, best_layout):
            best_layout = candidate

    if best_layout is None:
        die(
            f"impossible de calculer une résolution pour {bot_count} bots sur {max_workspaces} workspace(s)"
        )

    return best_layout.resolution.width, best_layout.resolution.height


def resolve_launch_resolution(
    *, bot_count: int, max_workspaces: int, sway: SwayLayoutConfig
) -> tuple[int, int]:
    return auto_resolution_for_workspaces(
        bot_count=bot_count,
        max_workspaces=max_workspaces,
        screen_width=sway.screen_width,
        screen_height=sway.screen_height,
    )


def build_sway_grid(width: int, height: int, sway: SwayLayoutConfig) -> SwayGrid:
    if width > sway.screen_width:
        die(
            f"résolution {width}x{height} trop large pour un écran sway de {sway.screen_width}px"
        )

    cols = sway.screen_width // width
    if cols <= 0:
        die(f"aucune colonne possible pour {width}x{height} sur {sway.screen_width}px")

    rows_per_workspace = sway.screen_height // height
    if rows_per_workspace <= 0:
        die(f"aucune rangée possible pour {width}x{height} sur {sway.screen_height}px")

    return SwayGrid(
        cols=cols,
        rows_per_workspace=rows_per_workspace,
        bots_per_workspace=cols * rows_per_workspace,
        x_margin=(sway.screen_width - cols * width) // 2,
        y_margin=(sway.screen_height - rows_per_workspace * height) // 2,
    )


def build_sway_header_lines(
    width: int,
    height: int,
    sway: SwayLayoutConfig,
    grid: SwayGrid,
) -> list[str]:
    return [
        'for_window [title="^WoW Mastermind$"] {\n',
        "    floating enable\n",
        "    border none\n",
        "    no_focus\n",
        "    move absolute position 0 0\n",
        "}\n",
        'for_window [title="^WoW - bot.*$"] {\n',
        "    floating enable\n",
        "    border none\n",
        "}\n",
        'for_window [title="^World of Warcraft"] {\n',
        "    floating enable\n",
        "    border none\n",
        "    no_focus\n",
        "    move absolute position 0 0\n",
        "}\n",
        "\n",
        "# Auto-generated by launch-client.py\n",
        f"# screen={sway.screen_width}x{sway.screen_height} y_offset={sway.y_offset} workspace_start={sway.workspace_start}\n",
        f"# window={width}x{height} cols={grid.cols} rows_per_workspace={grid.rows_per_workspace} x_margin={grid.x_margin} y_margin={grid.y_margin}\n",
    ]


def compute_sway_placement(
    zero_based: int,
    *,
    bot_count: int,
    width: int,
    height: int,
    sway: SwayLayoutConfig,
    grid: SwayGrid,
) -> SwayPlacement:
    workspace_offset = zero_based // grid.bots_per_workspace
    workspace = sway.workspace_start + workspace_offset
    slot = zero_based % grid.bots_per_workspace
    row = slot // grid.cols
    col = slot % grid.cols
    workspace_base = workspace_offset * grid.bots_per_workspace
    bots_remaining = bot_count - workspace_base
    bots_in_workspace = min(grid.bots_per_workspace, bots_remaining)
    rows_in_workspace = (bots_in_workspace + grid.cols - 1) // grid.cols
    row_start = row * grid.cols
    row_count = min(grid.cols, bots_in_workspace - row_start)
    row_x_margin = (sway.screen_width - row_count * width) // 2
    row_y_margin = (sway.screen_height - rows_in_workspace * height) // 2

    return SwayPlacement(
        workspace=workspace,
        x=row_x_margin + col * width,
        y=sway.y_offset + row_y_margin + row * height,
    )


def build_sway_bot_line(bot_id: int, placement: SwayPlacement) -> str:
    return (
        f'for_window [title="^WoW - bot{bot_id}$"] move absolute position '
        f"{placement.x} {placement.y}, move container to workspace {placement.workspace}\n"
    )


def print_layout_summary(
    bot_ids: list[int],
    *,
    width: int,
    height: int,
    sway: SwayLayoutConfig,
) -> None:
    bot_count = len(bot_ids)
    grid = build_sway_grid(width, height, sway)
    workspace_count = (
        bot_count + grid.bots_per_workspace - 1
    ) // grid.bots_per_workspace

    info(
        f"Layout: bots={bot_count} resolution={width}x{height} "
        f"cols={grid.cols} rows={grid.rows_per_workspace} "
        f"capacity={grid.bots_per_workspace} workspaces={workspace_count}"
    )
    for zero_based, bot_id in enumerate(bot_ids):
        placement = compute_sway_placement(
            zero_based,
            bot_count=bot_count,
            width=width,
            height=height,
            sway=sway,
            grid=grid,
        )
        info(
            f"  bot{bot_id}: workspace={placement.workspace} x={placement.x} y={placement.y}"
        )


def update_config_setting(config_path: str, key: str, value: str) -> None:
    if not os.path.isfile(config_path):
        die(f"Config.wtf introuvable : {config_path}")

    new_line = f'SET {key} "{value}"\n'
    with open(config_path, encoding="utf-8") as f:
        lines = f.readlines()

    for index, line in enumerate(lines):
        if line.startswith(f"SET {key} "):
            lines[index] = new_line
            break
    else:
        lines.append(new_line)

    with open(config_path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def update_config_resolution(config_path: str, resolution: str) -> None:
    update_config_setting(config_path, "gxResolution", resolution)


def update_config_refresh(config_path: str, refresh: int) -> None:
    update_config_setting(config_path, "gxRefresh", str(refresh))


def update_dxvk_fps(dxvk_conf_path: str, fps: int) -> None:
    if not os.path.isfile(dxvk_conf_path):
        die(f"dxvk.conf introuvable : {dxvk_conf_path}")

    key = "d3d9.maxFrameRate"
    new_line = f"{key} = {fps}\n"
    with open(dxvk_conf_path, encoding="utf-8") as f:
        lines = f.readlines()

    for index, line in enumerate(lines):
        if line.strip().startswith(f"{key} ="):
            lines[index] = new_line
            break
    else:
        lines.append(new_line)

    with open(dxvk_conf_path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def update_sway_layout(
    bot_ids: list[int],
    width: int,
    height: int,
    sway: SwayLayoutConfig,
) -> None:
    bot_count = len(bot_ids)
    grid = build_sway_grid(width, height, sway)
    lines = build_sway_header_lines(width, height, sway, grid)

    for zero_based, bot_id in enumerate(bot_ids):
        placement = compute_sway_placement(
            zero_based,
            bot_count=bot_count,
            width=width,
            height=height,
            sway=sway,
            grid=grid,
        )
        lines.append(build_sway_bot_line(bot_id, placement))

    with open(sway.config_path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def reload_sway() -> None:
    require_cmd("swaymsg")
    result = subprocess.run(
        ["swaymsg", "reload"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        die("swaymsg reload a échoué")


def prepare_client_runtime(clients_dir: str, expansion: str) -> None:
    expansion_dir = os.path.join(clients_dir, expansion)
    template_dir = os.path.join(clients_dir, "templates", expansion)
    wtf_template = os.path.join(template_dir, "WTF")
    dxvk_template = os.path.join(template_dir, "dxvk.conf")

    if not os.path.isdir(expansion_dir):
        die(f"dossier client introuvable : {expansion_dir}")
    if not os.path.isdir(template_dir):
        die(f"template client introuvable : {template_dir}")
    if not os.path.isdir(wtf_template):
        die(f"template WTF introuvable : {wtf_template}")
    if not os.path.isfile(dxvk_template):
        die(f"template dxvk introuvable : {dxvk_template}")

    wtf_dest = os.path.join(expansion_dir, "WTF")
    shutil.rmtree(wtf_dest, ignore_errors=True)
    shutil.copytree(wtf_template, wtf_dest)
    shutil.copy2(dxvk_template, expansion_dir)

    account_template = os.path.join(wtf_dest, "Account", "ACCOUNT_NAME")
    for i in range(1, MAX_BOTS + 1):
        dest = os.path.join(wtf_dest, "Account", f"BOT{i}")
        shutil.copytree(account_template, dest, dirs_exist_ok=True)


def run_wine_setup(prefix: str) -> None:
    env = {**os.environ, "WINEPREFIX": prefix}
    wine_result = subprocess.run(["wine", "setup"], env=env)
    if wine_result.returncode != 0:
        print(
            f"Avertissement : wine setup a retourné une erreur sur {prefix}, on tente quand même DXVK.",
            file=sys.stderr,
        )


def install_dxvk(prefix: str) -> None:
    env = {**os.environ, "WINEPREFIX": prefix}
    dxvk_result = subprocess.run(["setup_dxvk", "install", "--symlink"], env=env)
    if dxvk_result.returncode != 0:
        die(f"setup_dxvk a échoué sur {prefix}")


def install_dxvk_parallel(prefixes: list[str], max_workers: int) -> None:
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(install_dxvk, prefix): prefix for prefix in prefixes}
        for future in concurrent.futures.as_completed(futures):
            prefix = futures[future]
            try:
                future.result()
            except SystemExit as exc:
                die(f"setup_dxvk a échoué sur {prefix} (code {exc.code})")


# ── setup ─────────────────────────────────────────────────────────────────────


def do_setup(clients_dir: str, expansion: str) -> None:
    require_cmd("wine")
    require_cmd("zig")
    require_cmd("setup_dxvk")

    info("Nettoyage ~/.wine*...")
    home = os.path.expanduser("~")
    for entry in os.listdir(home):
        if entry.startswith(".wine"):
            shutil.rmtree(os.path.join(home, entry), ignore_errors=True)

    info("Building...")
    result = subprocess.run(["zig", "build"])
    if result.returncode != 0:
        die("zig build a échoué")

    info("Setup WTF...")
    prepare_client_runtime(clients_dir, expansion)

    template_prefix = template_prefix_path()

    info("Wine setup + DXVK sur le prefix modèle...")
    run_wine_setup(template_prefix)
    install_dxvk(template_prefix)

    info("Duplication du prefix modèle vers les bots...")
    bot_prefixes: list[str] = []
    for bot_id in range(1, MAX_BOTS + 1):
        dest_prefix = prefix_path(bot_id)
        shutil.rmtree(dest_prefix, ignore_errors=True)
        shutil.copytree(template_prefix, dest_prefix, symlinks=True)
        bot_prefixes.append(dest_prefix)

    info(
        f"Installation DXVK sur les prefixes bots ({DXVK_SETUP_PARALLELISM} en parallèle)..."
    )
    install_dxvk_parallel(bot_prefixes, DXVK_SETUP_PARALLELISM)


# ── launch ────────────────────────────────────────────────────────────────────


class BotProcess:
    def __init__(
        self,
        bot_id: int,
        wow_exe: str,
        stagger: float,
        mastermind_host: str,
        resolution: str,
    ):
        self.bot_id = bot_id
        self.wow_exe = wow_exe
        self.stagger = stagger
        self.mastermind_host = mastermind_host
        self.resolution = resolution
        self.proc: subprocess.Popen | None = None
        self._log_thread: threading.Thread | None = None

    def _pipe_logs(self, stream) -> None:
        prefix = f"[bot{self.bot_id}]"
        try:
            for line in stream:
                if line.strip():
                    print(f"{prefix} {line}", end="", flush=True)
        except ValueError:
            pass

    def start(self) -> None:
        bot = f"bot{self.bot_id}"
        prefix = prefix_path(self.bot_id)
        if not os.path.isdir(os.path.join(prefix, "drive_c")):
            die(f"[{bot}] prefix introuvable ({prefix}) — lancer --setup d'abord")

        info(f"[{bot}] Lancement {bot}...")
        env = {
            **os.environ,
            "DISPLAY": "",
            "WINEDEBUG": "-all",
            "WOW_CLIENTPATH": self.wow_exe,
            "BOT_ID": bot,
            "WINEPREFIX": prefix,
            "DXVK_LOG_LEVEL": "none",
            "MASTERMIND_HOST": self.mastermind_host,
            "WOW_RESOLUTION": self.resolution,
        }
        self.proc = subprocess.Popen(
            [
                "./zig-out/bin/launcher.exe",
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self._log_thread = threading.Thread(
            target=self._pipe_logs,
            args=(self.proc.stdout,),
            daemon=True,
        )
        self._log_thread.start()

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def kill(self) -> None:
        kill_prefix(self.bot_id)
        if self.proc is not None:
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None


def do_launch(
    bot_ids: list[int],
    config: LaunchConfig,
    *,
    print_layout_only: bool = False,
) -> None:
    bot_count = len(bot_ids)
    bot_label = format_bot_selector(bot_ids)
    width, height = resolve_launch_resolution(
        bot_count=bot_count,
        max_workspaces=config.max_workspaces,
        sway=config.sway,
    )
    resolution_str = format_resolution(width, height)
    info(f"Résolution WoW : {resolution_str}")
    print_layout_summary(bot_ids, width=width, height=height, sway=config.sway)

    if print_layout_only:
        return

    require_cmd("wine")

    if not os.path.isfile(config.wow_exe):
        die(f"Wow.exe introuvable : {config.wow_exe}")
    if not os.path.isfile("./zig-out/bin/launcher.exe"):
        die("launcher.exe introuvable — lancer --setup d'abord")

    info("Mise à jour des fichiers WTF / DXVK...")
    prepare_client_runtime(config.clients_dir, config.expansion)

    expansion_dir = os.path.join(config.clients_dir, config.expansion)
    config_path = os.path.join(expansion_dir, "WTF", "Config.wtf")
    dxvk_conf_path = os.path.join(expansion_dir, "dxvk.conf")
    update_config_resolution(config_path, resolution_str)
    update_config_refresh(config_path, config.fps)
    update_dxvk_fps(dxvk_conf_path, config.fps)
    update_sway_layout(
        bot_ids,
        width,
        height,
        config.sway,
    )
    info(f"Mise à jour du layout sway : {config.sway.config_path}")
    info("Reload de sway...")
    reload_sway()

    # Kill any already-running bots in range
    alive = [i for i in bot_ids if prefix_active(i)]
    if alive:
        info(f"Kill bots {format_bot_selector(alive)} en cours...")
        for i in alive:
            kill_prefix(i)
        wait_dead(bot_ids, KILL_TIMEOUT)

    bots = [
        BotProcess(
            i,
            config.wow_exe,
            config.stagger,
            config.mastermind_host,
            resolution_str,
        )
        for i in bot_ids
    ]

    stopping = False

    def shutdown(signum, frame):
        nonlocal stopping
        stopping = True
        print("", file=sys.stderr)
        info(f"Arrêt des bots {bot_label}...")
        for b in bots:
            b.kill()
        wait_dead(bot_ids, KILL_TIMEOUT)
        info(f"Bots {bot_label} arrêtés.")
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    # Initial staggered launch
    for idx, bot in enumerate(bots):
        bot.start()
        if idx < len(bots) - 1:
            time.sleep(config.stagger)

    info(f"Bots {bot_label} lancés. Ctrl-C pour tout arrêter.")

    # Watch loop: restart bots that die
    while not stopping:
        for bot in bots:
            if not stopping and not bot.is_alive():
                info(f"[bot{bot.bot_id}] process mort — relancement...")
                bot.start()
        time.sleep(2)


# ── main ──────────────────────────────────────────────────────────────────────


def parse_args():
    parser = argparse.ArgumentParser(
        description="Lance et supervise des bots WoW sous Wine.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Variables d'environnement :
  EXPANSION          Nom du dossier client (défault : wotlk)
  WOW_CLIENTPATH     Chemin vers Wow.exe  (défaut : ./clients/$EXPANSION/Wow.exe)
  WOW_STAGGER        Délai entre bots (s) (défaut : {DEFAULT_STAGGER})
  WOW_FPS            Cap FPS              (défaut : {DEFAULT_FPS})
  SWAY_SCREEN_WIDTH  Largeur écran sway   (défaut : {DEFAULT_SWAY_SCREEN_WIDTH})
  SWAY_SCREEN_HEIGHT Hauteur écran sway   (défaut : {DEFAULT_SWAY_SCREEN_HEIGHT})
  SWAY_Y_OFFSET      Départ vertical bots (défaut : {DEFAULT_SWAY_Y_OFFSET})
  SWAY_WORKSPACE     Premier workspace    (défaut : {DEFAULT_SWAY_WORKSPACE})
  SWAY_CONFIG_PATH   Fichier layout sway  (défaut : {DEFAULT_SWAY_CONFIG_PATH})
  MASTERMIND_HOST    Adresse du mastermind  (défaut : 127.0.0.1)
""",
    )
    parser.add_argument("--setup", action="store_true")
    parser.add_argument("--launch", action="store_true")
    parser.add_argument(
        "--print-layout",
        action="store_true",
        help="Affiche la résolution et les placements sans lancer WoW",
    )
    parser.add_argument(
        "--bots",
        required=True,
        help="Bots à lancer: liste/plages séparées par virgules (ex: 1-2,5-6,8)",
    )
    parser.add_argument("--max-workspaces", type=int, default=1)
    return parser.parse_args()


def load_launch_config(args: argparse.Namespace) -> LaunchConfig:
    expansion = os.environ.get("EXPANSION", "wotlk")

    clients_dir = os.path.realpath("./clients")
    if not os.path.isdir(clients_dir):
        die(f"répertoire clients introuvable : ./clients")

    return LaunchConfig(
        wow_exe=os.environ.get(
            "WOW_CLIENTPATH", os.path.join(clients_dir, expansion, "Wow.exe")
        ),
        expansion=expansion,
        clients_dir=clients_dir,
        stagger=parse_stagger(os.environ.get("WOW_STAGGER", str(DEFAULT_STAGGER))),
        mastermind_host=os.environ.get("MASTERMIND_HOST", "127.0.0.1"),
        fps=parse_fps(os.environ.get("WOW_FPS", str(DEFAULT_FPS))),
        max_workspaces=args.max_workspaces,
        sway=SwayLayoutConfig(
            screen_width=parse_int(
                os.environ.get("SWAY_SCREEN_WIDTH", str(DEFAULT_SWAY_SCREEN_WIDTH)),
                "SWAY_SCREEN_WIDTH",
                minimum=1,
            ),
            screen_height=parse_int(
                os.environ.get("SWAY_SCREEN_HEIGHT", str(DEFAULT_SWAY_SCREEN_HEIGHT)),
                "SWAY_SCREEN_HEIGHT",
                minimum=1,
            ),
            y_offset=parse_int(
                os.environ.get("SWAY_Y_OFFSET", str(DEFAULT_SWAY_Y_OFFSET)),
                "SWAY_Y_OFFSET",
                minimum=0,
            ),
            workspace_start=parse_int(
                os.environ.get("SWAY_WORKSPACE", str(DEFAULT_SWAY_WORKSPACE)),
                "SWAY_WORKSPACE",
                minimum=1,
            ),
            config_path=os.environ.get("SWAY_CONFIG_PATH", DEFAULT_SWAY_CONFIG_PATH),
        ),
    )


def main():
    args = parse_args()

    if not args.setup and not args.launch:
        args.launch = True

    bot_ids = parse_bot_selector(args.bots)
    if not bot_ids:
        die("--bots ne peut pas être vide")
    if bot_ids[0] < 1 or bot_ids[-1] > MAX_BOTS:
        die(f"--bots doit rester dans [1, {MAX_BOTS}]")
    if args.max_workspaces <= 0:
        die("--max-workspaces doit être >= 1")

    config = load_launch_config(args)

    if args.setup:
        do_setup(config.clients_dir, config.expansion)

    if args.launch:
        do_launch(bot_ids, config, print_layout_only=args.print_layout)


if __name__ == "__main__":
    main()
