(() => {
  const tokenFromUrl = new URLSearchParams(window.location.search).get("token") || "";
  let tokenFromStorage = "";
  try {
    if (tokenFromUrl) {
      window.sessionStorage.setItem("robloxMcpInstallerToken", tokenFromUrl);
    }
    tokenFromStorage = window.sessionStorage.getItem("robloxMcpInstallerToken") || "";
  } catch {
    tokenFromStorage = "";
  }
  if (tokenFromUrl) {
    window.history.replaceState(null, "", `${window.location.pathname}${window.location.hash}`);
  }
  const installerToken = tokenFromUrl || tokenFromStorage;

  const state = {
    harnesses: [],
    selected: new Set(),
    filter: "detected",
    search: "",
    screen: "select",
    furthestScreenIndex: 0,
    skipHarnessSetup: false,
    installSkill: true,
    installConnector: true,
    selectedConnectorTargets: new Set(),
    connector: {
      platform: null,
      scriptName: "roblox-executor-mcp.lua",
      targets: [],
      detectedTargets: [],
    },
    serviceMode: "background",
    backgroundService: null,
    restartMode: null,
    skill: {
      name: "roblox-mcp",
      path: "skills/roblox-mcp",
    },
    preview: true,
    requiresInstallToken: false,
    installing: false,
    installStatus: null,
    manualRecipe: null,
  };

  const elements = {
    list: document.getElementById("harnessList"),
    loading: document.getElementById("loadingState"),
    empty: document.getElementById("emptyState"),
    search: document.getElementById("harnessSearch"),
    count: document.getElementById("selectionCount"),
    continueButton: document.getElementById("continueButton"),
    skipHarnessButton: document.getElementById("skipHarnessButton"),
    manualInstallButton: document.getElementById("manualInstallButton"),
    manualInstallDialog: document.getElementById("manualInstallDialog"),
    closeManualInstallDialog: document.getElementById("closeManualInstallDialog"),
    copyManualInstallButton: document.getElementById("copyManualInstallButton"),
    manualInstallRecipe: document.getElementById("manualInstallRecipe"),
    backButton: document.getElementById("backButton"),
    installSkillCheckbox: document.getElementById("installSkillCheckbox"),
    installConnectorCheckbox: document.getElementById("installConnectorCheckbox"),
    connectorTargets: document.getElementById("connectorTargets"),
    connectorEmptyState: document.getElementById("connectorEmptyState"),
    connectorNote: document.getElementById("connectorNote"),
    connectorSelectionCount: document.getElementById("connectorSelectionCount"),
    skillExplainer: document.getElementById("skillExplainer"),
    skillTargetSummary: document.getElementById("skillTargetSummary"),
    restartDialog: document.getElementById("restartDialog"),
    restartHarnesses: document.getElementById("restartHarnesses"),
    closeRestartDialog: document.getElementById("closeRestartDialog"),
    manualRestartButton: document.getElementById("manualRestartButton"),
    automaticRestartButton: document.getElementById("automaticRestartButton"),
    serviceNotice: document.getElementById("serviceNotice"),
    serviceNoticeTitle: document.getElementById("serviceNoticeTitle"),
    serviceDescription: document.getElementById("serviceDescription"),
    serviceAdvancedSelection: document.getElementById("serviceAdvancedSelection"),
    serviceManager: document.getElementById("serviceManager"),
    openServiceDialog: document.getElementById("openServiceDialog"),
    serviceDialog: document.getElementById("serviceDialog"),
    closeServiceDialog: document.getElementById("closeServiceDialog"),
    doneServiceDialog: document.getElementById("doneServiceDialog"),
    headerTitle: document.getElementById("headerTitle"),
    modeLabel: document.getElementById("modeLabel"),
    modeDot: document.getElementById("modeDot"),
    modeLabelText: document.getElementById("modeLabelText"),
    installDialog: document.getElementById("installDialog"),
    installDialogTitle: document.getElementById("installDialogTitle"),
    installStatusIcon: document.getElementById("installStatusIcon"),
    installStatusTitle: document.getElementById("installStatusTitle"),
    installStatusMessage: document.getElementById("installStatusMessage"),
    installConsole: document.getElementById("installConsole"),
    closeInstallDialog: document.getElementById("closeInstallDialog"),
    doneInstallDialog: document.getElementById("doneInstallDialog"),
    installationSuccess: document.getElementById("installationSuccess"),
    installationSuccessTitle: document.getElementById("installationSuccessTitle"),
    installationSuccessDetail: document.getElementById("installationSuccessDetail"),
    successConfetti: document.getElementById("successConfetti"),
  };
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  document.querySelectorAll("[data-filter]").forEach((button) => {
    button.addEventListener("click", () => {
      state.filter = button.dataset.filter;
      document.querySelectorAll("[data-filter]").forEach((item) => {
        item.classList.toggle("is-active", item === button);
      });
      renderHarnesses();
    });
  });

  elements.search.addEventListener("input", () => {
    state.search = elements.search.value.trim().toLowerCase();
    renderHarnesses();
  });

  elements.continueButton.addEventListener("click", () => {
    if (state.screen === "select") {
      if (state.selected.size === 0) return;
      state.skipHarnessSetup = false;
      const runningHarnesses = selectedHarnesses()
        .filter((harness) => harness.running === true);
      if (runningHarnesses.length > 0) {
        openRestartDialog(runningHarnesses);
        return;
      }
      showScreen("skill");
      return;
    }
    if (state.screen === "skill") {
      showScreen("connector");
      return;
    }
    if (state.screen === "connector") {
      showScreen("service");
      return;
    }
    if (state.screen === "service") startInstallation();
  });

  elements.skipHarnessButton.addEventListener("click", () => {
    state.skipHarnessSetup = true;
    state.restartMode = null;
    showScreen("skill");
  });

  elements.backButton.addEventListener("click", () => {
    const sequence = ["select", "skill", "connector", "service"];
    const previous = sequence[Math.max(0, sequence.indexOf(state.screen) - 1)];
    if (previous === "select") {
      state.skipHarnessSetup = false;
      state.restartMode = null;
    }
    showScreen(previous);
  });

  elements.installSkillCheckbox.addEventListener("change", () => {
    state.installSkill = elements.installSkillCheckbox.checked;
    renderSkill();
  });
  elements.installConnectorCheckbox.addEventListener("change", () => {
    state.installConnector = elements.installConnectorCheckbox.checked;
    state.selectedConnectorTargets = state.installConnector
      ? new Set(state.connector.detectedTargets.map((target) => target.id))
      : new Set();
    renderConnector();
    renderActions();
  });
  document.querySelectorAll('input[name="serviceMode"]').forEach((input) => {
    input.addEventListener("change", () => {
      if (!input.checked) return;
      state.serviceMode = input.value;
      renderService();
      renderActions();
    });
  });
  document.querySelectorAll("[data-step-indicator]").forEach((step) => {
    step.querySelector(".step-button").addEventListener("click", () => {
      const sequence = ["select", "skill", "connector", "service"];
      const targetIndex = sequence.indexOf(step.dataset.stepIndicator);
      if (targetIndex <= state.furthestScreenIndex) {
        showScreen(sequence[targetIndex]);
      }
    });
  });

  elements.closeRestartDialog.addEventListener("click", () => closeRestartDialog());
  elements.restartDialog.addEventListener("click", (event) => {
    if (event.target === elements.restartDialog) closeRestartDialog();
  });
  elements.openServiceDialog.addEventListener("click", () => openServiceDialog());
  elements.closeServiceDialog.addEventListener("click", () => closeServiceDialog());
  elements.doneServiceDialog.addEventListener("click", () => closeServiceDialog());
  elements.serviceDialog.addEventListener("click", (event) => {
    if (event.target === elements.serviceDialog) closeServiceDialog();
  });
  elements.closeInstallDialog.addEventListener("click", () => closeInstallDialog());
  elements.doneInstallDialog.addEventListener("click", () => closeInstallDialog());
  elements.installDialog.addEventListener("click", (event) => {
    if (event.target === elements.installDialog && !state.installing) closeInstallDialog();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    if (!elements.installDialog.hidden && !state.installing) {
      closeInstallDialog({ animate: false });
    } else if (!elements.manualInstallDialog.hidden) closeManualInstallDialog({ animate: false });
    else if (!elements.serviceDialog.hidden) closeServiceDialog({ animate: false });
    else if (!elements.restartDialog.hidden) closeRestartDialog({ animate: false });
  });
  elements.manualInstallButton.addEventListener("click", () => openManualInstallDialog());
  elements.closeManualInstallDialog.addEventListener("click", () => closeManualInstallDialog());
  elements.manualInstallDialog.addEventListener("click", (event) => {
    if (event.target === elements.manualInstallDialog) closeManualInstallDialog();
  });
  elements.copyManualInstallButton.addEventListener("click", () => copyManualRecipe());
  elements.manualRestartButton.addEventListener("click", () => chooseRestartMode("manual"));
  elements.automaticRestartButton.addEventListener("click", () => chooseRestartMode("automatic"));

  loadHarnesses();

  async function loadHarnesses() {
    try {
      const response = await fetch("/api/harnesses", { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error(`Harness detection failed (${response.status})`);
      const data = await response.json();
      state.preview = data.preview === true;
      state.requiresInstallToken = data.requiresInstallToken === true;
      state.harnesses = Array.isArray(data.harnesses) ? data.harnesses : [];
      if (data.skill && typeof data.skill === "object") {
        state.skill = {
          name: data.skill.name || state.skill.name,
          path: data.skill.path || state.skill.path,
        };
      }
      if (data.connector && typeof data.connector === "object") {
        state.connector = {
          platform: data.connector.platform || null,
          scriptName: data.connector.scriptName || state.connector.scriptName,
          targets: Array.isArray(data.connector.targets)
            ? data.connector.targets
            : [],
          detectedTargets: Array.isArray(data.connector.detectedTargets)
            ? data.connector.detectedTargets
            : [],
        };
        state.selectedConnectorTargets = new Set(
          state.connector.detectedTargets.map((target) => target.id)
        );
      }
      state.backgroundService =
        data.backgroundService && typeof data.backgroundService === "object"
          ? data.backgroundService
          : null;
      state.manualRecipe =
        data.manualRecipe && typeof data.manualRecipe === "object" && typeof data.manualRecipe.json === "string"
          ? data.manualRecipe
          : null;
      for (const harness of state.harnesses) {
        if (harness.detected) state.selected.add(harness.id);
      }
      elements.loading.hidden = true;
      renderInstallerMode();
      renderHarnesses();
      renderConnector();
      renderService();
      renderActions();
    } catch (error) {
      elements.loading.replaceChildren();
      const message = document.createElement("span");
      message.textContent = error instanceof Error ? error.message : "Could not detect harnesses.";
      elements.loading.append(message);
      elements.count.textContent = "Detection unavailable";
    }
  }

  function renderHarnesses() {
    const visible = state.harnesses.filter((harness) => {
      if (state.filter === "detected" && !harness.detected) return false;
      return !state.search
        || harness.name.toLowerCase().includes(state.search)
        || harness.id.toLowerCase().includes(state.search);
    });

    elements.list.replaceChildren(...visible.map((harness, index) => createHarnessRow(harness, index)));
    elements.list.hidden = visible.length === 0;
    elements.empty.hidden = visible.length !== 0;
    renderActions();
  }

  function createHarnessRow(harness, index) {
    const label = document.createElement("label");
    label.className = "harness-row";
    label.style.setProperty("--row-index", String(Math.min(index, 8)));

    const checkbox = document.createElement("input");
    checkbox.className = "harness-check";
    checkbox.type = "checkbox";
    checkbox.checked = state.selected.has(harness.id);
    checkbox.addEventListener("change", () => {
      if (checkbox.checked) state.selected.add(harness.id);
      else state.selected.delete(harness.id);
      renderActions();
    });

    const copy = document.createElement("span");
    copy.className = "harness-copy";

    const name = document.createElement("span");
    name.className = "harness-name";
    name.append(document.createTextNode(harness.name));
    if (harness.group === "Others") {
      const group = document.createElement("span");
      group.className = "experimental";
      group.textContent = "Other";
      name.append(group);
    }

    const meta = document.createElement("span");
    meta.className = "harness-meta";
    meta.textContent = harness.reason || (harness.detected ? "Detected locally" : "Supported config target");
    copy.append(name, meta);

    const status = document.createElement("span");
    status.className = `status${harness.manualRestartRequired ? " is-manual" : harness.detected ? " is-detected" : ""}`;
    status.textContent = harness.manualRestartRequired
      ? "Restart manually"
      : harness.detected
        ? "Detected"
        : "Not found";

    label.append(checkbox, copy, status);
    return label;
  }

  function renderActions() {
    if (state.screen === "select") {
      const count = state.selected.size;
      elements.count.textContent = count === 1 ? "1 harness selected" : `${count} harnesses selected`;
      elements.continueButton.disabled = count === 0;
      elements.continueButton.textContent = "Continue";
      return;
    }
    if (state.screen === "skill") {
      elements.count.textContent = skillStatus();
      elements.continueButton.disabled = false;
      elements.continueButton.textContent = "Continue";
      return;
    }
    if (state.screen === "connector") {
      const count = state.selectedConnectorTargets.size;
      elements.count.textContent = state.installConnector
        ? `${count} connector target${count === 1 ? "" : "s"}`
        : "Connector installation skipped";
      elements.continueButton.disabled = false;
      elements.continueButton.textContent = "Continue";
      return;
    }
    elements.count.textContent =
      state.serviceMode === "background"
        ? `${state.backgroundService?.manager || "Native service"} selected`
        : "On-demand server selected";
    if (state.preview) {
      elements.continueButton.disabled = true;
      elements.continueButton.textContent = "Installation disabled";
      return;
    }
    const missingToken = state.requiresInstallToken && !installerToken;
    elements.continueButton.disabled = state.installing || missingToken;
    elements.continueButton.textContent = state.installing
      ? "Installing…"
      : missingToken
        ? "Secure link required"
        : "Install";
    if (missingToken) {
      elements.count.textContent = "Open the secure installer link printed in the terminal";
    }
  }

  function renderScreen() {
    const sequence = ["select", "skill", "connector", "service"];
    const activeIndex = sequence.indexOf(state.screen);
    document.querySelectorAll("[data-screen]").forEach((screen) => {
      screen.classList.toggle("is-active", screen.dataset.screen === state.screen);
    });
    document.querySelectorAll("[data-step-indicator]").forEach((step) => {
      const name = step.dataset.stepIndicator;
      const stepIndex = sequence.indexOf(name);
      step.classList.toggle("is-active", name === state.screen);
      step.classList.toggle(
        "is-complete",
        stepIndex < activeIndex
      );
      step.querySelector(".step-button").disabled =
        stepIndex > state.furthestScreenIndex;
    });
    elements.backButton.hidden = state.screen === "select";
    elements.skipHarnessButton.hidden = state.screen !== "select";
    if (state.screen === "skill") renderSkill();
    if (state.screen === "connector") renderConnector();
    if (state.screen === "service") renderService();
    renderActions();
  }

  function showScreen(screen) {
    state.screen = screen;
    state.furthestScreenIndex = Math.max(
      state.furthestScreenIndex,
      ["select", "skill", "connector", "service"].indexOf(screen)
    );
    renderScreen();
  }

  function openRestartDialog(harnesses) {
    elements.restartHarnesses.replaceChildren(...harnesses.map((harness) => {
      const item = document.createElement("div");
      item.className = "restart-item";
      const name = document.createElement("strong");
      name.textContent = harness.restartLabel || harness.name;
      const status = document.createElement("span");
      status.textContent = "Running";
      item.append(name, status);
      return item;
    }));
    elements.restartDialog.classList.remove("is-closing");
    elements.restartDialog.hidden = false;
    elements.manualRestartButton.focus();
  }

  function closeRestartDialog({ animate = true, onComplete } = {}) {
    if (elements.restartDialog.hidden || elements.restartDialog.classList.contains("is-closing")) return;

    const finish = () => {
      elements.restartDialog.hidden = true;
      elements.restartDialog.classList.remove("is-closing");
      if (typeof onComplete === "function") onComplete();
      else elements.continueButton.focus();
    };

    if (!animate || reducedMotion.matches) {
      finish();
      return;
    }

    elements.restartDialog.classList.add("is-closing");
    window.setTimeout(finish, 140);
  }

  function openManualInstallDialog() {
    const recipe = state.manualRecipe?.json || "";
    elements.manualInstallRecipe.textContent = recipe || "MCP recipe is unavailable.";
    elements.copyManualInstallButton.disabled = !recipe;
    elements.manualInstallDialog.classList.remove("is-closing");
    elements.manualInstallDialog.hidden = false;
    elements.copyManualInstallButton.focus();
  }

  function closeManualInstallDialog({ animate = true } = {}) {
    if (elements.manualInstallDialog.hidden || elements.manualInstallDialog.classList.contains("is-closing")) return;
    const finish = () => {
      elements.manualInstallDialog.hidden = true;
      elements.manualInstallDialog.classList.remove("is-closing");
      elements.manualInstallButton.focus();
    };
    if (!animate || reducedMotion.matches) {
      finish();
      return;
    }
    elements.manualInstallDialog.classList.add("is-closing");
    window.setTimeout(finish, 140);
  }

  async function copyManualRecipe() {
    const recipe = state.manualRecipe?.json || "";
    if (!recipe) return;
    try {
      await navigator.clipboard.writeText(recipe);
      elements.copyManualInstallButton.textContent = "Copied";
    } catch {
      elements.copyManualInstallButton.textContent = "Copy failed";
    }
    window.setTimeout(() => {
      elements.copyManualInstallButton.textContent = "Copy";
    }, 1200);
  }

  function openServiceDialog() {
    elements.serviceDialog.classList.remove("is-closing");
    elements.serviceDialog.hidden = false;
    const selected = elements.serviceDialog.querySelector(
      `input[name="serviceMode"][value="${state.serviceMode}"]`
    );
    selected?.focus();
  }

  function closeServiceDialog({ animate = true } = {}) {
    if (
      elements.serviceDialog.hidden
      || elements.serviceDialog.classList.contains("is-closing")
    ) return;

    const finish = () => {
      elements.serviceDialog.hidden = true;
      elements.serviceDialog.classList.remove("is-closing");
      elements.openServiceDialog.focus();
    };

    if (!animate || reducedMotion.matches) {
      finish();
      return;
    }

    elements.serviceDialog.classList.add("is-closing");
    window.setTimeout(finish, 140);
  }

  function chooseRestartMode(mode) {
    state.restartMode = mode;
    closeRestartDialog({ onComplete: () => showScreen("skill") });
  }

  function selectedHarnesses() {
    return state.harnesses.filter((harness) => state.selected.has(harness.id));
  }

  function skillHarnesses() {
    const source = state.skipHarnessSetup
      ? state.harnesses.filter((harness) => harness.detected)
      : selectedHarnesses();
    return source.filter((harness) => typeof harness.skillAgent === "string" && harness.skillAgent);
  }

  function skillAgentIds() {
    return [...new Set(skillHarnesses().map((harness) => harness.skillAgent))];
  }

  function renderSkill() {
    const agentIds = skillAgentIds();
    elements.skillExplainer.classList.toggle("is-disabled", !state.installSkill);
    elements.skillTargetSummary.textContent = !state.installSkill
      ? "Skill installation skipped."
      : agentIds.length > 0
        ? `Available to ${agentIds.join(", ")}.`
        : "No compatible detected agents are available.";
    renderActions();
  }

  function skillStatus() {
    if (!state.installSkill) return "Skill installation skipped";
    const prefix = state.skipHarnessSetup ? "Harness setup skipped · " : "";
    const restart = state.restartMode ? ` · ${state.restartMode} restart selected` : "";
    return `${prefix}${skillAgentIds().length} skill targets${restart}`;
  }

  function renderConnector() {
    const targets = state.connector.detectedTargets;
    elements.installConnectorCheckbox.disabled = targets.length === 0;
    if (targets.length === 0) {
      state.installConnector = false;
      state.selectedConnectorTargets.clear();
      elements.installConnectorCheckbox.checked = false;
      elements.installConnectorCheckbox.indeterminate = false;
      elements.connectorTargets.replaceChildren();
      elements.connectorTargets.hidden = true;
      elements.connectorEmptyState.hidden = false;
      elements.connectorNote.hidden = true;
      elements.connectorSelectionCount.textContent = "No targets";
      return;
    }
    elements.connectorTargets.hidden = false;
    elements.connectorEmptyState.hidden = true;
    elements.connectorNote.hidden = false;
    const selectedCount = state.selectedConnectorTargets.size;
    state.installConnector = selectedCount > 0;
    elements.installConnectorCheckbox.checked = selectedCount === targets.length;
    elements.installConnectorCheckbox.indeterminate =
      selectedCount > 0 && selectedCount < targets.length;
    elements.connectorSelectionCount.textContent =
      `${selectedCount} of ${targets.length} selected`;
    elements.connectorTargets.replaceChildren(
      ...targets.map((target, index) => {
        const row = document.createElement("label");
        row.className = "harness-row connector-target";
        row.style.setProperty("--row-index", String(Math.min(index, 8)));

        const checkbox = document.createElement("input");
        checkbox.className = "harness-check";
        checkbox.type = "checkbox";
        checkbox.checked = state.selectedConnectorTargets.has(target.id);
        checkbox.addEventListener("change", () => {
          if (checkbox.checked) state.selectedConnectorTargets.add(target.id);
          else state.selectedConnectorTargets.delete(target.id);
          renderConnector();
          renderActions();
        });

        const copy = document.createElement("span");
        copy.className = "harness-copy";
        const name = document.createElement("span");
        name.className = "harness-name";
        name.textContent = target.name;
        const folder = document.createElement("span");
        folder.className = "harness-meta";
        folder.textContent = target.folder;
        copy.append(name, folder);
        const status = document.createElement("span");
        status.className = `status is-detected${target.installed ? " is-installed" : ""}`;
        status.textContent = target.installed ? "Update existing" : "Ready";
        row.append(checkbox, copy, status);
        return row;
      })
    );
    elements.connectorNote.textContent = state.installConnector
      ? `${state.connector.scriptName} will be written to the selected targets.`
      : "Automatic connector installation is skipped.";
  }

  function renderService() {
    const plan = state.backgroundService;
    elements.serviceManager.textContent = plan?.manager || "Native service";
    const background = state.serviceMode === "background";
    elements.serviceNotice.classList.toggle("is-on-demand", !background);
    elements.serviceNoticeTitle.textContent = background
      ? "Roblox MCP will run in the background"
      : "Roblox MCP will start when a harness connects";
    elements.serviceDescription.textContent = background
      ? `${plan?.description || "It starts automatically with your computer."} It stays available after the dashboard is closed.`
      : "The first harness starts the shared server. It can stop after every harness disconnects.";
    elements.serviceAdvancedSelection.textContent = background
      ? "Background · Recommended"
      : "On demand";
  }

  function renderInstallerMode() {
    const previewOnly = document.querySelectorAll("[data-preview-only]");
    previewOnly.forEach((element) => {
      element.hidden = !state.preview;
    });
    elements.headerTitle.textContent = state.preview ? "Installer Preview" : "Installer";
    elements.modeLabelText.textContent = state.preview
      ? "Preview mode · no changes"
      : installerToken
        ? "Ready to install"
        : "Secure link required";
    elements.modeDot.classList.toggle("is-ready", !state.preview && Boolean(installerToken));
    elements.modeDot.classList.toggle("is-error", !state.preview && !installerToken);
    elements.modeLabel.dataset.mode = state.preview ? "preview" : "installer";
  }

  async function startInstallation() {
    if (state.preview || state.installing || (state.requiresInstallToken && !installerToken)) return;

    state.installing = true;
    state.installStatus = {
      status: "running",
      step: "prepare",
      message: "Preparing the installation…",
    };
    openInstallDialog();
    renderActions();
    renderInstallStatus();

    try {
      const response = await fetch("/api/install", {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-Roblox-MCP-Installer-Token": installerToken,
        },
        body: JSON.stringify({
          harnessIds: [...state.selected],
          skipHarnessSetup: state.skipHarnessSetup,
          installSkill: state.installSkill,
          connectorTargetIds: state.installConnector
            ? [...state.selectedConnectorTargets]
            : [],
          serviceMode: state.serviceMode,
          restartMode: state.restartMode || "automatic",
        }),
      });
      const payload = await readJsonResponse(response);
      if (!response.ok) {
        throw new Error(payload.error || `Installation could not start (${response.status}).`);
      }
      state.installStatus = payload.installation;
      renderInstallStatus();
      await pollInstallStatus();
    } catch (error) {
      state.installStatus = {
        status: "error",
        step: state.installStatus?.step || "prepare",
        message: error instanceof Error ? error.message : "Installation failed.",
      };
      state.installing = false;
      renderInstallStatus();
      renderActions();
    }
  }

  async function pollInstallStatus() {
    while (state.installing) {
      await delay(500);
      const response = await fetch("/api/install/status", {
        headers: {
          Accept: "application/json",
          "X-Roblox-MCP-Installer-Token": installerToken,
        },
      });
      const payload = await readJsonResponse(response);
      if (!response.ok) {
        throw new Error(payload.error || `Could not read installation status (${response.status}).`);
      }
      state.installStatus = payload;
      if (payload.status !== "running") state.installing = false;
      renderInstallStatus();
      renderActions();
    }
  }

  function openInstallDialog() {
    elements.installDialog.classList.remove("is-closing");
    elements.installDialog.hidden = false;
    elements.closeInstallDialog.hidden = true;
    elements.doneInstallDialog.hidden = true;
  }

  function closeInstallDialog({ animate = true } = {}) {
    if (
      state.installing
      || elements.installDialog.hidden
      || elements.installDialog.classList.contains("is-closing")
    ) return;

    const finish = () => {
      elements.installDialog.hidden = true;
      elements.installDialog.classList.remove("is-closing");
      elements.continueButton.focus();
    };
    if (!animate || reducedMotion.matches) {
      finish();
      return;
    }
    elements.installDialog.classList.add("is-closing");
    window.setTimeout(finish, 140);
  }

  function renderInstallStatus() {
    const status = state.installStatus || {};
    const succeeded = status.status === "success";
    const failed = status.status === "error";
    const complete = succeeded || failed;
    const details = Array.isArray(status.details) ? status.details : [];
    const consoleText = details.length > 0 ? details.join("\n") : "Waiting for command output…";
    if (elements.installConsole.textContent !== consoleText) {
      elements.installConsole.textContent = consoleText;
      elements.installConsole.scrollTop = elements.installConsole.scrollHeight;
    }
    if (succeeded) {
      showInstallationSuccess(status);
      return;
    }
    elements.installDialogTitle.textContent = failed
      ? "Installation failed"
      : "Installing Roblox MCP";
    elements.installStatusTitle.textContent = failed
      ? "Roblox MCP could not be installed"
      : status.message || "Preparing the installation…";
    elements.installStatusMessage.textContent = complete
      ? status.message || "Check the terminal for more details."
      : "Keep this page open while Roblox MCP is configured.";
    elements.installStatusIcon.className = `install-status-icon${failed ? " is-error" : ""}`;
    elements.installStatusIcon.replaceChildren();
    if (!complete) {
      const spinner = document.createElement("span");
      spinner.className = "spinner";
      elements.installStatusIcon.append(spinner);
    } else {
      elements.installStatusIcon.textContent = "!";
    }
    const order = ["server", "skill", "service"];
    let activeStep = status.step === "prepare" ? "server" : status.step;
    if (status.step === "complete") activeStep = null;
    const activeIndex = order.indexOf(activeStep);
    document.querySelectorAll("[data-install-step]").forEach((item) => {
      const index = order.indexOf(item.dataset.installStep);
      item.classList.toggle(
        "is-complete",
        index < activeIndex || (index === 1 && !state.installSkill)
      );
      item.classList.toggle("is-active", !complete && index === activeIndex);
      item.classList.toggle("is-error", failed && index === Math.max(activeIndex, 0));
    });
    elements.closeInstallDialog.hidden = !complete;
    elements.doneInstallDialog.hidden = !complete;
    if (complete) elements.doneInstallDialog.focus();
  }

  function showInstallationSuccess(status) {
    if (!elements.installationSuccess.hidden) return;

    elements.installDialog.hidden = true;
    document.querySelectorAll("[data-screen]").forEach((screen) => {
      screen.classList.remove("is-active");
    });
    document.body.classList.add("is-installation-success");
    elements.headerTitle.textContent = "Installation complete";
    elements.modeLabelText.textContent = "Roblox MCP is ready";
    elements.modeDot.classList.add("is-ready");
    elements.modeDot.classList.remove("is-error");
    elements.installationSuccessDetail.textContent =
      status.message || "Roblox MCP is ready.";
    elements.installationSuccess.hidden = false;

    window.requestAnimationFrame(() => {
      elements.installationSuccess.classList.add("is-visible");
      elements.installationSuccessTitle.focus({ preventScroll: true });
    });
    launchSuccessConfetti();
  }

  function launchSuccessConfetti() {
    if (reducedMotion.matches || !elements.successConfetti.hidden) return;

    const colors = ["#63b77c", "#d7a85f", "#ededed", "#3b82f6"];
    const fragment = document.createDocumentFragment();
    for (let index = 0; index < 34; index += 1) {
      const piece = document.createElement("span");
      piece.className = "confetti-piece";
      piece.style.setProperty("--x", `${3 + ((index * 37) % 94)}%`);
      piece.style.setProperty("--width", `${5 + (index % 4)}px`);
      piece.style.setProperty("--height", `${8 + (index % 3) * 2}px`);
      piece.style.setProperty("--confetti-color", colors[index % colors.length]);
      piece.style.setProperty("--delay", `${(index % 9) * 45}ms`);
      piece.style.setProperty("--duration", `${1800 + (index % 7) * 110}ms`);
      piece.style.setProperty("--drift", `${((index * 19) % 121) - 60}px`);
      piece.style.setProperty("--spin", `${360 + (index % 5) * 180}deg`);
      fragment.append(piece);
    }
    elements.successConfetti.replaceChildren(fragment);
    elements.successConfetti.hidden = false;
    window.setTimeout(() => {
      elements.successConfetti.hidden = true;
      elements.successConfetti.replaceChildren();
    }, 3000);
  }

  async function readJsonResponse(response) {
    try {
      return await response.json();
    } catch {
      return {};
    }
  }

  function delay(milliseconds) {
    return new Promise((resolve) => window.setTimeout(resolve, milliseconds));
  }
})();
