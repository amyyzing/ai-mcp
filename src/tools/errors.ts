import type { ToolTextResponse } from "./factory.js";

export const NO_CLIENT_ERROR: ToolTextResponse = {
  content: [
    {
      type: "text",
      text: "No Roblox client connected to the MCP server. Please notify the user that they have to run the connector.luau script in order to connect the MCP server to their game.",
    },
  ],
  isError: true,
};

export const INVALID_CLIENT_ERROR: ToolTextResponse = {
  content: [
    {
      type: "text",
      text: "Invalid client ID provided. Please use the list-clients tool to get a list of valid client IDs.",
    },
  ],
  isError: true,
};

export const AMBIGUOUS_CLIENT_ERROR: ToolTextResponse = {
  content: [
    {
      type: "text",
      text: "Multiple Roblox clients are connected and no target was selected. Pass clientId to this tool or call list-clients then set-active-client first.",
    },
  ],
  isError: true,
};

export const CLIENT_QUEUE_FULL_ERROR: ToolTextResponse = {
  content: [
    {
      type: "text",
      text: "The Roblox client's pending command queue is full. The request was not sent; wait for the client to resume polling and retry.",
    },
  ],
  isError: true,
};

export const BRIDGE_BUSY_ERROR: ToolTextResponse = {
  content: [
    {
      type: "text",
      text: "The MCP bridge has too many pending requests. This request was not sent; wait for current calls to finish and retry.",
    },
  ],
  isError: true,
};
