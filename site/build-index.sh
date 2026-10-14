#!/usr/bin/env bash
# Génère l'index du site (texte pour curl, HTML pour navigateur)
# à partir des lignes "# DESC:" présentes dans chaque script.
# Les scripts sont regroupés par dossier (pve/, linux/, debian/...).
#
# Usage : build-index.sh <dossier_repo> <dossier_sortie> [url_de_base]
set -euo pipefail
# Bash 5.2+ : sinon "&" dans un remplacement ${s//x/y} est remplacé par le texte trouvé
shopt -u patsub_replacement 2>/dev/null || true

REPO="${1:?Usage : build-index.sh <repo> <sortie> [url]}"
OUT="${2:?Usage : build-index.sh <repo> <sortie> [url]}"
BASE_URL="${3:-https://get.andries.icu}"
HOST="${BASE_URL#https://}"; HOST="${HOST#http://}"

# Dossiers qui ne contiennent pas de scripts publics
EXCLUDE_DIRS=(site templates .git .github)

# Nom lisible des dossiers connus (les autres gardent leur nom)
group_label() {
  case "$1" in
    pve)     echo "Proxmox VE" ;;
    pbs)     echo "Proxmox Backup Server" ;;
    linux)   echo "Linux (Debian, Ubuntu, Rocky)" ;;
    debian)  echo "Debian" ;;
    ubuntu)  echo "Ubuntu" ;;
    rocky)   echo "Rocky Linux" ;;
    lxc)     echo "Conteneurs LXC" ;;
    docker)  echo "Docker" ;;
    net)     echo "Réseau" ;;
    mac)     echo "macOS" ;;
    test)    echo "Tests" ;;
    .)       echo "Divers" ;;
    *)       echo "$1" ;;
  esac
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; s="${s//\'/&#39;}"
  printf '%s' "$s"
}

get_desc() {
  grep -m1 '^# DESC:' "$REPO/$1" 2>/dev/null | sed 's/^# DESC:[[:space:]]*//' || true
}

plural() { if [ "$1" -gt 1 ]; then echo "s"; fi; }

main() {
  mkdir -p "$OUT"
  local tmp_txt tmp_html
  tmp_txt="$(mktemp)"; tmp_html="$(mktemp)"

  local prune=() d
  for d in "${EXCLUDE_DIRS[@]}"; do
    prune+=(-path "$REPO/$d" -prune -o)
  done

  # Liste triée des scripts (chemins relatifs)
  local scripts=() f
  while IFS= read -r f; do
    scripts+=("$f")
  done < <(find "$REPO" "${prune[@]}" -type f -name '*.sh' -print | sed "s#^$REPO/##" | LC_ALL=C sort)

  # Liste des dossiers, dans l'ordre
  local groups=() g rel
  for rel in "${scripts[@]}"; do
    g="$(dirname "$rel")"
    if [[ " ${groups[*]-} " != *" $g "* ]]; then groups+=("$g"); fi
  done

  local commit commit_date
  commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"
  commit_date="$(git -C "$REPO" log -1 --format=%cd --date=format:'%d/%m/%Y à %H:%M' 2>/dev/null || echo '')"

  local name desc count n dsc

  # ================================================================ Texte (curl)
  {
    echo "get.andries.icu — scripts d'Alexis (commit $commit)"
    echo
    echo "Lancer :       curl -fsSL $BASE_URL/<script> | bash"
    echo "Avec options : curl -fsSL $BASE_URL/<script> | bash -s -- --help"
    echo "Lire avant :   curl -fsSL $BASE_URL/<script> | less"
    for g in "${groups[@]}"; do
      echo
      echo "$(group_label "$g")"
      for rel in "${scripts[@]}"; do
        if [ "$(dirname "$rel")" != "$g" ]; then continue; fi
        name="${rel%.sh}"
        desc="$(get_desc "$rel")"
        printf '  %-24s %s\n' "$name" "${desc:-(pas de description)}"
      done
    done
    echo
    echo "Secours : https://raw.githubusercontent.com/MortalDemon3/scripts/main/<script>.sh"
  } > "$tmp_txt"

  # ================================================================ HTML (navigateur)
  local first_name=""
  if [ "${#scripts[@]}" -gt 0 ]; then first_name="${scripts[0]%.sh}"; fi
  local date_txt=""
  if [ -n "$commit_date" ]; then date_txt=" du $commit_date"; fi

  {
    cat <<EOF
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>get.andries.icu</title>
<meta name="description" content="Scripts d'administration d'Alexis, à lancer d'une seule commande.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<style>
  :root {
    --bg:       #E8EDF2;
    --panel:    #F6F8FA;
    --ink:      #1D2733;
    --muted:    #56657A;
    --line:     #C8D2DC;
    --accent:   #2C66B0;
    --accent-ink: #FFFFFF;
    --ok:       #2F7A53;
    --term-bg:  #1D2733;
    --term-ink: #DCE5EE;
    --term-dim: #8FA1B5;
    --term-hi:  #9CC7F5;
    --sans: "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
    --mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg:       #141D27;
      --panel:    #1B2633;
      --ink:      #E2E9F0;
      --muted:    #98A8B9;
      --line:     #2C3A4A;
      --accent:   #7DB0EA;
      --accent-ink: #10202F;
      --ok:       #7CC49C;
      --term-bg:  #0E161F;
      --term-ink: #DCE5EE;
      --term-dim: #7E93AB;
      --term-hi:  #9CC7F5;
    }
  }

  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--ink);
    font: 16px/1.55 var(--sans);
  }
  a { color: var(--accent); text-underline-offset: 2px; }
  :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 4px; }
  .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }

  .wrap { max-width: 960px; margin: 0 auto; padding: 0 16px; }

  /* ---------- En-tête */
  header { padding: 48px 0 0; }
  .brand {
    font: 600 clamp(28px, 5vw, 40px)/1.1 var(--mono);
    letter-spacing: -0.02em;
    margin: 0 0 10px;
  }
  .brand span { color: var(--muted); font-weight: 400; }
  .lead { margin: 0; color: var(--muted); max-width: 62ch; }

  /* ---------- La ligne de commande : l'élément principal de la page */
  .term {
    margin-top: 28px;
    background: var(--term-bg);
    color: var(--term-ink);
    border-radius: 10px;
    padding: 18px 18px 16px;
  }
  .term-label { margin: 0 0 10px; font-size: 14px; color: var(--term-dim); }
  .term-row { display: flex; gap: 12px; align-items: center; }
  .term code {
    flex: 1; min-width: 0;
    font: 400 clamp(14px, 2.2vw, 18px)/1.5 var(--mono);
    overflow-x: auto; white-space: nowrap;
    padding: 4px 0;
    scrollbar-width: thin;
  }
  .term .prompt { color: var(--term-dim); user-select: none; }
  .term .sel { color: var(--term-hi); font-weight: 600; }
  .term-links { margin: 12px 0 0; font-size: 14px; color: var(--term-dim); }
  .term-links a { color: var(--term-hi); }
  .term-links code { font: 13px var(--mono); color: var(--term-ink); white-space: nowrap; }

  .btn {
    font: 600 14px/1 var(--sans);
    border: 0; border-radius: 8px;
    padding: 11px 18px;
    background: var(--accent); color: var(--accent-ink);
    cursor: pointer; white-space: nowrap;
  }
  .btn.done { background: var(--ok); color: #fff; }

  /* ---------- Recherche */
  .search { margin: 36px 0 4px; position: relative; }
  .search input {
    width: 100%;
    font: 400 16px/1.4 var(--sans);
    color: var(--ink);
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 12px 44px 12px 14px;
  }
  .search input::placeholder { color: var(--muted); }
  .search input:focus { outline: 2px solid var(--accent); outline-offset: 0; border-color: transparent; }
  .search kbd {
    position: absolute; right: 12px; top: 50%; transform: translateY(-50%);
    font: 12px/1 var(--mono); color: var(--muted);
    border: 1px solid var(--line); border-radius: 4px; padding: 4px 7px;
  }

  /* ---------- Groupes de scripts */
  main { padding-bottom: 56px; }
  .group { margin-top: 36px; }
  .group[hidden] { display: none; }
  .group-head {
    display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap;
    margin: 0; padding-bottom: 8px;
    border-bottom: 2px solid var(--ink);
  }
  .group-head h2 { margin: 0; font-size: 20px; font-weight: 600; }
  .group-head .path { font: 14px var(--mono); color: var(--muted); }
  .group-head .count { margin-left: auto; font-size: 14px; color: var(--muted); }

  ul.scripts { list-style: none; margin: 0; padding: 0; }
  .script {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 2px 16px;
    align-items: center;
    padding: 14px 12px 14px 13px;
    border-bottom: 1px solid var(--line);
    border-left: 3px solid transparent;
    cursor: pointer;
  }
  .script[hidden] { display: none; }
  .script:hover { background: var(--panel); }
  .script[aria-current="true"] { background: var(--panel); border-left-color: var(--accent); }
  .script .name { font: 600 16px/1.35 var(--mono); }
  .script .desc { grid-column: 1; margin: 0; color: var(--muted); font-size: 15px; }
  .script .desc.empty { font-style: italic; }
  .script .actions {
    grid-column: 2; grid-row: 1 / span 2;
    display: flex; gap: 14px; align-items: center;
  }
  .script .actions a { font-size: 14px; }
  .btn-sm {
    font: 600 13px/1 var(--sans);
    background: transparent; color: var(--accent);
    border: 1px solid var(--accent); border-radius: 6px;
    padding: 8px 12px; cursor: pointer; white-space: nowrap;
  }
  .btn-sm.done { color: var(--ok); border-color: var(--ok); }

  .empty-state { margin: 40px 0; color: var(--muted); }
  .empty-state[hidden] { display: none; }

  footer { border-top: 1px solid var(--line); padding: 20px 0 40px; font-size: 14px; color: var(--muted); }
  footer p { margin: 4px 0; }
  footer code { font: 13px var(--mono); overflow-wrap: anywhere; }

  @media (max-width: 620px) {
    header { padding-top: 32px; }
    .term-row { flex-direction: column; align-items: stretch; }
    .term code { white-space: normal; overflow-wrap: anywhere; }
    .script { grid-template-columns: 1fr; }
    .script .actions { grid-column: 1; grid-row: auto; margin-top: 8px; }
    .search kbd { display: none; }
  }
  @media (prefers-reduced-motion: no-preference) {
    .btn, .btn-sm { transition: background-color .15s, color .15s, border-color .15s; }
  }
</style>
</head>
<body>
<div class="wrap">

<header>
  <h1 class="brand">get<span>.andries.icu</span></h1>
  <p class="lead">Mes scripts d'administration, à lancer sur n'importe quelle machine avec une seule commande. Choisis un script dans la liste, copie la commande, puis colle-la dans un terminal root.</p>

  <section class="term" aria-labelledby="term-label">
    <p class="term-label" id="term-label">Commande pour lancer le script sélectionné</p>
    <div class="term-row">
      <code id="cmd"><span class="prompt"># </span>curl -fsSL https://$(html_escape "$HOST")/<span class="sel" id="cmd-sel">$(html_escape "$first_name")</span> | bash</code>
      <button class="btn" id="copy-main" type="button">Copier</button>
    </div>
    <p class="term-links">
      <a id="read-link" href="/$(html_escape "$first_name")">Lire le script avant de le lancer</a>.
      Pour voir ses options, remplace <code>| bash</code> par <code>| bash -s -- --help</code>.
    </p>
  </section>
</header>

<main>
  <div class="search">
    <label for="q" class="sr-only">Rechercher un script</label>
    <input id="q" type="search" placeholder="Rechercher un script (nom ou description)" autocomplete="off">
    <kbd>/</kbd>
  </div>
EOF

    for g in "${groups[@]}"; do
      count=0
      for rel in "${scripts[@]}"; do
        if [ "$(dirname "$rel")" = "$g" ]; then count=$((count + 1)); fi
      done
      cat <<EOF

  <section class="group" data-group>
    <div class="group-head">
      <h2>$(html_escape "$(group_label "$g")")</h2>
      <span class="path">$(if [ "$g" = . ]; then echo "/"; else html_escape "$g/"; fi)</span>
      <span class="count">$count script$(plural "$count")</span>
    </div>
    <ul class="scripts">
EOF
      for rel in "${scripts[@]}"; do
        if [ "$(dirname "$rel")" != "$g" ]; then continue; fi
        name="${rel%.sh}"
        desc="$(get_desc "$rel")"
        n="$(html_escape "$name")"
        if [ -n "$desc" ]; then
          dsc="<p class=\"desc\">$(html_escape "$desc")</p>"
        else
          dsc='<p class="desc empty">Pas de description : ajoute une ligne « # DESC: » en haut du script.</p>'
        fi
        cat <<EOF
      <li class="script" data-name="$n" data-search="$(html_escape "${name,,} ${desc,,}")" tabindex="0">
        <span class="name">$n</span>
        $dsc
        <span class="actions">
          <a href="/$n">Code</a>
          <button class="btn-sm" type="button" data-copy>Copier</button>
        </span>
      </li>
EOF
      done
      cat <<EOF
    </ul>
  </section>
EOF
    done

    cat <<EOF

  <p class="empty-state" id="empty" hidden>Aucun script ne correspond à cette recherche. Essaie un autre mot, ou appuie sur Échap pour tout réafficher.</p>
</main>

<footer>
  <p>${#scripts[@]} script$(plural "${#scripts[@]}") en ligne, version $(html_escape "$commit")$(html_escape "$date_txt"). Source sur <a href="https://github.com/MortalDemon3/scripts">GitHub</a>.</p>
  <p>Si ce site ne répond pas, passe par GitHub : <code>curl -fsSL https://raw.githubusercontent.com/MortalDemon3/scripts/main/&lt;script&gt;.sh | bash</code></p>
</footer>

</div>
<script>
(function () {
  var HOST = "$(html_escape "$HOST")";
  var sel = document.getElementById("cmd-sel");
  var readLink = document.getElementById("read-link");
  var mainBtn = document.getElementById("copy-main");
  var items = Array.prototype.slice.call(document.querySelectorAll(".script"));

  function command(name) { return "curl -fsSL https://" + HOST + "/" + name + " | bash"; }

  function fallback(text) {
    var t = document.createElement("textarea");
    t.value = text; t.style.position = "fixed"; t.style.opacity = "0";
    document.body.appendChild(t); t.select();
    try { document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(t);
  }
  function copy(text, btn) {
    function done() {
      btn.textContent = "Copié";
      btn.classList.add("done");
      setTimeout(function () { btn.textContent = "Copier"; btn.classList.remove("done"); }, 1500);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, function () { fallback(text); done(); });
    } else { fallback(text); done(); }
  }

  function select(li) {
    items.forEach(function (x) { x.removeAttribute("aria-current"); });
    li.setAttribute("aria-current", "true");
    var name = li.getAttribute("data-name");
    sel.textContent = name;
    readLink.href = "/" + name;
  }

  items.forEach(function (li) {
    li.addEventListener("click", function (e) {
      if (e.target.closest("a")) return;
      select(li);
    });
    li.addEventListener("keydown", function (e) {
      if (e.target !== li) return;
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); select(li); }
    });
    li.querySelector("[data-copy]").addEventListener("click", function (e) {
      e.stopPropagation();
      select(li);
      copy(command(li.getAttribute("data-name")), e.currentTarget);
    });
  });
  if (items[0]) items[0].setAttribute("aria-current", "true");

  mainBtn.addEventListener("click", function () { copy(command(sel.textContent), mainBtn); });

  // Recherche
  var q = document.getElementById("q");
  var empty = document.getElementById("empty");
  var groups = Array.prototype.slice.call(document.querySelectorAll("[data-group]"));
  function filter() {
    var terms = q.value.toLowerCase().trim().split(/\s+/).filter(Boolean);
    var shown = 0;
    groups.forEach(function (g) {
      var visible = 0;
      g.querySelectorAll(".script").forEach(function (li) {
        var hay = li.getAttribute("data-search");
        var ok = terms.every(function (t) { return hay.indexOf(t) !== -1; });
        li.hidden = !ok;
        if (ok) visible++;
      });
      g.hidden = visible === 0;
      shown += visible;
    });
    empty.hidden = shown !== 0;
  }
  q.addEventListener("input", filter);

  // "/" pour aller dans la recherche, Échap pour l'effacer
  document.addEventListener("keydown", function (e) {
    if (e.key === "/" && document.activeElement !== q) { e.preventDefault(); q.focus(); }
    else if (e.key === "Escape" && document.activeElement === q) { q.value = ""; filter(); q.blur(); }
  });
})();
</script>
</body>
</html>
EOF
  } > "$tmp_html"

  # Remplacement atomique : nginx ne sert jamais un fichier à moitié écrit
  install -m 644 "$tmp_txt" "$OUT/index.txt.new" && mv -f "$OUT/index.txt.new" "$OUT/index.txt"
  install -m 644 "$tmp_html" "$OUT/index.html.new" && mv -f "$OUT/index.html.new" "$OUT/index.html"
  rm -f "$tmp_txt" "$tmp_html"
  echo "Index généré : ${#scripts[@]} script(s) dans ${#groups[@]} dossier(s), commit $commit"
}

main "$@"
