import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ToolRoutingContext } from "./factory.js";
import registerSetActiveClient from "./impl/clients/set-active-client.js";
import registerListClients from "./impl/clients/list-clients.js";

import registerExecute from "./impl/execution/execute.js";
import registerExecuteFile from "./impl/execution/execute-file.js";

import registerGetScriptContent from "./impl/inspection/get-script-content.js";
import registerGetDataByCode from "./impl/inspection/get-data-by-code.js";
import registerGetConsoleOutput from "./impl/inspection/get-console-output.js";
import registerSearchInstances from "./impl/inspection/search-instances.js";
import registerScriptGrep from "./impl/inspection/script-grep.js";
import registerSemanticSearchScripts from "./impl/inspection/semantic-search-scripts.js";
import registerGetGameInfo from "./impl/inspection/get-game-info.js";
import registerGetDescendantsTree from "./impl/inspection/get-descendants-tree.js";

import registerRemoteSpy from "./impl/remote-spy/remote-spy.js";

import registerTypeTextBox from "./impl/gui/type-text-box.js";
import registerClickButton from "./impl/gui/click-button.js";

import registerScreenshotWindow from "./impl/windows/screenshot-window.js";
import registerListRobloxWindows from "./impl/windows/list-roblox-windows.js";
import registerRuntimeStatus from "./impl/advanced/runtime-status.js";
import registerInspectInstance from "./impl/advanced/inspect-instance.js";
import registerSearchGc from "./impl/advanced/search-gc.js";
import registerWaitForEvent from "./impl/advanced/wait-for-event.js";
import registerInput from "./impl/advanced/input.js";
import registerScriptIndex from "./impl/advanced/script-index.js";
import registerListScripts from "./impl/advanced/list-scripts.js";
import registerDevirtualizeLuraph from "./impl/advanced/devirtualize-luraph.js";
import registerRuntimeTools from "./impl/runtime/runtime-tools.js";

export function registerAllTools(server: McpServer, routing: ToolRoutingContext): void {
  registerSetActiveClient(server, routing);

  registerListClients(server, routing);

  registerExecute(server, routing);
  registerExecuteFile(server, routing);

  registerGetScriptContent(server, routing);
  registerGetDataByCode(server, routing);
  registerGetConsoleOutput(server, routing);
  registerSearchInstances(server, routing);
  registerScriptGrep(server, routing);
  registerSemanticSearchScripts(server, routing);
  registerGetGameInfo(server, routing);
  registerGetDescendantsTree(server, routing);

  registerRemoteSpy(server, routing);

  registerRuntimeStatus(server, routing);
  registerInspectInstance(server, routing);
  registerSearchGc(server, routing);
  registerWaitForEvent(server, routing);
  registerInput(server, routing);
  registerScriptIndex(server, routing);
  registerListScripts(server, routing);
  registerDevirtualizeLuraph(server, routing);
  registerRuntimeTools(server, routing);

  registerTypeTextBox(server, routing);
  registerClickButton(server, routing);

  registerScreenshotWindow(server);
  registerListRobloxWindows(server);
}
