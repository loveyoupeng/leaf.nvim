---Explorer probing: the file under the cursor in a neo-tree filesystem
---panel becomes a File Source. Kept out of resolve.lua so the decision
---layer stays pure — init.lua calls this while building the context.

local M = {}

---@class leaf.ExplorerNode
---@field path string Node path (may be relative to cwd)
---@field is_dir boolean True when the node is a directory

---@param bufnr integer
---@return boolean
local function is_neotree(bufnr)
  return vim.bo[bufnr].filetype == "neo-tree"
end

---Node under the cursor, when the given buffer is a neo-tree panel.
---@param bufnr integer
---@return leaf.ExplorerNode?
function M.node(bufnr)
  if not is_neotree(bufnr) then
    return nil
  end
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok then
    return nil
  end
  local state = manager.get_state("filesystem")
  if not (state and state.tree) then
    return nil
  end
  -- tree:get_node() with no id reads the cursor line of the tree's window;
  -- valid because :Leaf only probes when focus is inside the panel.
  local ok_node, node = pcall(function()
    return state.tree:get_node()
  end)
  if not ok_node or not node or not node.path then
    return nil
  end
  return { path = node.path, is_dir = node.type == "directory" }
end

return M
