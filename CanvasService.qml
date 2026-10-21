import Quickshell
import Quickshell.Io
import QtQuick
import qs.Commons

// Headless Canvas service. Owns the project list and document storage on disk,
// and answers IPC so other Omarchy pieces (bar widget, menu entries, hotkeys)
// can list projects, create new canvases, and query status without summoning
// the window.
//
// The panel (CanvasPanel.qml) is the editor; this service is the index. Both
// point at the same files under ~/.local/state/omarchy/canvas/, so anything
// created from the CLI or a hotkey is immediately visible in the editor.

Item {
  id: root

  property string dataDir: Quickshell.env("HOME") + "/.local/state/omarchy/canvas"
  property string currentDoc: "default"

  // ---- project index ------------------------------------------------------

  // Scans the data dir for *.json documents. Returns a plain array of
  // { id, name, path, modified, size } so callers can render their own lists.
  function listProjects() {
    var out = []
    var dirs = [dataDir]
    for (var d = 0; d < dirs.length; d++) {
      var proc = listProc
      proc.command = ["bash", "-c",
        "for f in " + Util.shellQuote(dirs[d]) + "/*.json; do [ -f \"$f\" ] || continue; "
        + "printf '%s\\t%s\\t%s\\n' \"$(basename \"$f\" .json)\" \"$(stat -c %Y \"$f\")\" \"$(stat -c %s \"$f\")\"; done"]
      proc.running = true
      break
    }
    return out
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var rows = String(text || "").trim().split("\n")
        var out = []
        for (var i = 0; i < rows.length; i++) {
          var parts = rows[i].split("\t")
          if (parts.length < 3) continue
          out.push({ id: parts[0], modified: Number(parts[1]), size: Number(parts[2]) })
        }
        root.projects = out
      }
    }
  }

  property var projects: ([])

  function projectName(id) {
    if (id === "default") return "Untitled canvas"
    return String(id).replace(/[-_]+/g, " ").replace(/\b\w/g, function (c) { return c.toUpperCase() })
  }

  function documentPath(id) {
    return dataDir + "/" + String(id) + ".json"
  }

  function ensureDir() {
    dirProc.command = ["bash", "-c", "mkdir -p " + Util.shellQuote(dataDir)]
    dirProc.running = true
  }

  Process {
    id: dirProc
    onExited: root.listProjects()
  }

  // ---- operations ---------------------------------------------------------

  // Create a new empty document and return its id.
  function createProject(name) {
    var id = String(name || ("project-" + Date.now()))
    id = id.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "project-" + Date.now()
    var payload = JSON.stringify({
      version: 1, docId: id, title: root.projectName(id), nextId: 1,
      gridSize: 20, showGrid: true, camX: 0, camY: 0, zoom: 1, objects: []
    })
    writeProc.command = ["bash", "-c",
      "mkdir -p " + Util.shellQuote(dataDir) + " && printf %s " + Util.shellQuote(payload)
      + " > " + Util.shellQuote(documentPath(id))]
    writeProc.running = true
    return id
  }

  Process {
    id: writeProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: root.listProjects()
  }

  function deleteProject(id) {
    if (id === "default") return false
    deleteProc.command = ["bash", "-c", "rm -f " + Util.shellQuote(documentPath(id))]
    deleteProc.running = true
    return true
  }

  Process {
    id: deleteProc
    onExited: root.listProjects()
  }

  function setCurrent(id) {
    currentDoc = String(id)
  }

  // ---- IPC ---------------------------------------------------------------
  // Target: "canvas". Lets other Omarchy components drive the canvas without
  // knowing the panel's internals.
  IpcHandler {
    target: "canvas"

    function ping(): string { return "ok" }

    function list(): string {
      root.listProjects()
      return JSON.stringify({
        dir: root.dataDir,
        current: root.currentDoc,
        projects: root.projects.map(function (p) {
          return { id: p.id, name: root.projectName(p.id), modified: p.modified, size: p.size }
        })
      })
    }

    function create(name: string): string {
      root.ensureDir()
      var id = root.createProject(name || "")
      return JSON.stringify({ id: id, name: root.projectName(id) })
    }

    function remove(id: string): string {
      return root.deleteProject(id) ? "ok" : "unknown"
    }

    function open(id: string): string {
      // Summon the panel pointed at this document.
      if (root.shell && typeof root.shell.summon === "function") {
        root.shell.summon("io.github.hermes.canvas", JSON.stringify({ doc: id }))
        return "ok"
      }
      return "no-shell"
    }

    function current(): string { return root.currentDoc }
  }

  Component.onCompleted: {
    root.ensureDir()
    Qt.callLater(root.listProjects)
  }
}
