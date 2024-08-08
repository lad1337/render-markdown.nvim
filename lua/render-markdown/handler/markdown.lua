local Context = require('render-markdown.context')
local NodeInfo = require('render-markdown.node_info')
local code_block_parser = require('render-markdown.parser.code_block')
local colors = require('render-markdown.colors')
local component = require('render-markdown.component')
local icons = require('render-markdown.icons')
local list = require('render-markdown.list')
local logger = require('render-markdown.logger')
local pipe_table_parser = require('render-markdown.parser.pipe_table')
local state = require('render-markdown.state')
local str = require('render-markdown.str')

---@class render.md.handler.buf.Markdown
---@field private buf integer
---@field private config render.md.BufferConfig
---@field private context render.md.Context
---@field private last_heading_border integer
---@field private marks render.md.Mark[]
local Handler = {}
Handler.__index = Handler

---@param buf integer
---@return render.md.handler.buf.Markdown
function Handler.new(buf)
    local self = setmetatable({}, Handler)
    self.buf = buf
    self.config = state.get_config(buf)
    self.context = Context.get(buf)
    self.last_heading_border = -1
    self.marks = {}
    return self
end

---@param root TSNode
---@return render.md.Mark[]
function Handler:parse(root)
    self.context:query(root, state.markdown_query, function(capture, node)
        local info = NodeInfo.new(self.buf, node)
        logger.debug_node_info(capture, info)
        if capture == 'heading' then
            self:heading(info)
        elseif capture == 'dash' then
            self:dash(info)
        elseif capture == 'code' then
            self:code(info)
        elseif capture == 'list_marker' then
            self:list_marker(info)
        elseif capture == 'checkbox_unchecked' then
            self:checkbox(info, self.config.checkbox.unchecked)
        elseif capture == 'checkbox_checked' then
            self:checkbox(info, self.config.checkbox.checked)
        elseif capture == 'quote' then
            self.context:query(node, state.markdown_quote_query, function(nested_capture, nested_node)
                local nested_info = NodeInfo.new(self.buf, nested_node)
                logger.debug_node_info(nested_capture, nested_info)
                if nested_capture == 'quote_marker' then
                    self:quote_marker(nested_info, info)
                else
                    logger.unhandled_capture('markdown quote', nested_capture)
                end
            end)
        elseif capture == 'table' then
            self:pipe_table(info)
        else
            logger.unhandled_capture('markdown', capture)
        end
    end)
    return self.marks
end

---@private
---@param conceal boolean
---@param start_row integer
---@param start_col integer
---@param opts vim.api.keyset.set_extmark
---@return boolean
function Handler:add(conceal, start_row, start_col, opts)
    return list.add_mark(self.marks, conceal, start_row, start_col, opts)
end

---@private
---@param info render.md.NodeInfo
function Handler:heading(info)
    local heading = self.config.heading
    if not heading.enabled then
        return
    end

    local level = str.width(info.text)
    local foreground = list.clamp(heading.foregrounds, level)
    local background = list.clamp(heading.backgrounds, level)

    local icon_width = self:heading_icon(info, level, foreground, background)
    if heading.sign then
        self:sign(info, list.cycle(heading.signs, level), foreground)
    end

    self:add(true, info.start_row, 0, {
        end_row = info.end_row + 1,
        end_col = 0,
        hl_group = background,
        hl_eol = true,
    })

    local width = self:heading_width(info, icon_width)
    if heading.width == 'block' then
        -- Overwrite anything beyond width with Normal
        self:add(true, info.start_row, 0, {
            priority = 0,
            virt_text = { { str.pad(vim.o.columns * 2), 'Normal' } },
            virt_text_win_col = width,
        })
    end
    if heading.border then
        self:heading_border(info, level, foreground, colors.inverse(background), width)
    end

    if heading.left_pad > 0 then
        self:add(false, info.start_row, 0, {
            priority = 0,
            virt_text = { { str.pad(heading.left_pad), background } },
            virt_text_pos = 'inline',
        })
    end
end

---@private
---@param info render.md.NodeInfo
---@param level integer
---@param foreground string
---@param background string
---@return integer
function Handler:heading_icon(info, level, foreground, background)
    local heading = self.config.heading
    local icon = list.cycle(heading.icons, level)

    -- Available width is level + 1 - concealed, where level = number of `#` characters, one
    -- is added to account for the space after the last `#` but before the heading title,
    -- and concealed text is subtracted since that space is not usable
    local width = level + 1 - self.context:concealed(info)
    if icon == nil then
        return width
    end

    local padding = width - str.width(icon)
    if heading.position == 'inline' or padding < 0 then
        self:add(true, info.start_row, info.start_col, {
            end_row = info.end_row,
            end_col = info.end_col,
            virt_text = { { icon, { foreground, background } } },
            virt_text_pos = 'inline',
            conceal = '',
        })
        return str.width(icon)
    else
        self:add(true, info.start_row, info.start_col, {
            end_row = info.end_row,
            end_col = info.end_col,
            virt_text = { { str.pad(padding, icon), { foreground, background } } },
            virt_text_pos = 'overlay',
        })
        return width
    end
end

---@private
---@param info render.md.NodeInfo
---@param icon_width integer
---@return integer
function Handler:heading_width(info, icon_width)
    local heading = self.config.heading
    if heading.width == 'block' then
        local width = heading.left_pad + icon_width + heading.right_pad
        local content = info:sibling('inline')
        if content ~= nil then
            width = width + str.width(content.text) + self.context:link_width(content) - self.context:concealed(content)
        end
        return math.max(width, heading.min_width)
    else
        return self.context:get_width()
    end
end

---@private
---@param info render.md.NodeInfo
---@param level integer
---@param foreground string
---@param background string
---@param width integer
function Handler:heading_border(info, level, foreground, background, width)
    local heading = self.config.heading
    local prefix = heading.border_prefix and level or 0

    local line_above = {
        { heading.above:rep(heading.left_pad), background },
        { heading.above:rep(prefix), foreground },
        { heading.above:rep(width - heading.left_pad - prefix), background },
    }
    if str.width(info:line('above')) == 0 and info.start_row - 1 ~= self.last_heading_border then
        self:add(true, info.start_row - 1, 0, {
            virt_text = line_above,
            virt_text_pos = 'overlay',
        })
    else
        self:add(false, info.start_row, 0, {
            virt_lines = { line_above },
            virt_lines_above = true,
        })
    end

    local line_below = {
        { heading.below:rep(heading.left_pad), background },
        { heading.below:rep(prefix), foreground },
        { heading.below:rep(width - heading.left_pad - prefix), background },
    }
    if str.width(info:line('below')) == 0 then
        self:add(true, info.end_row + 1, 0, {
            virt_text = line_below,
            virt_text_pos = 'overlay',
        })
        self.last_heading_border = info.end_row + 1
    else
        self:add(false, info.end_row, 0, {
            virt_lines = { line_below },
        })
    end
end

---@private
---@param info render.md.NodeInfo
function Handler:dash(info)
    local dash = self.config.dash
    if not dash.enabled then
        return
    end

    local width
    if dash.width == 'full' then
        width = self.context:get_width()
    else
        ---@type integer
        width = dash.width
    end

    self:add(true, info.start_row, 0, {
        virt_text = { { dash.icon:rep(width), dash.highlight } },
        virt_text_pos = 'overlay',
    })
end

---@private
---@param info render.md.NodeInfo
function Handler:code(info)
    local code = self.config.code
    if not code.enabled or code.style == 'none' then
        return
    end
    local code_block = code_block_parser.parse(code, self.context, info)
    if code_block == nil then
        return
    end

    local add_background = vim.tbl_contains({ 'normal', 'full' }, code.style)
    add_background = add_background and not vim.tbl_contains(code.disable_background, code_block.language)

    local icon_added = self:language(code_block, add_background)
    if add_background then
        self:code_background(code_block, icon_added)
    end
    self:code_left_pad(code_block, add_background)
end

---@private
---@param code_block render.md.parsed.CodeBlock
---@param add_background boolean
---@return boolean
function Handler:language(code_block, add_background)
    local code = self.config.code
    if not vim.tbl_contains({ 'language', 'full' }, code.style) then
        return false
    end
    local info = code_block.language_info
    if info == nil then
        return false
    end
    local icon, icon_highlight = icons.get(info.text)
    if icon == nil or icon_highlight == nil then
        return false
    end
    if code.sign then
        self:sign(info, icon, icon_highlight)
    end
    local highlight = { icon_highlight }
    if add_background then
        table.insert(highlight, code.highlight)
    end
    if code.position == 'left' then
        local icon_text = icon .. ' '
        if self.context:hidden(info) then
            -- Code blocks will pick up varying amounts of leading white space depending on the
            -- context they are in. This gets lumped into the delimiter node and as a result,
            -- after concealing, the extmark will be left shifted. Logic below accounts for this.
            icon_text = str.pad(code_block.leading_spaces, icon_text .. info.text)
        end
        return self:add(true, info.start_row, info.start_col, {
            virt_text = { { icon_text, highlight } },
            virt_text_pos = 'inline',
        })
    elseif code.position == 'right' then
        local icon_text = icon .. ' ' .. info.text
        local win_col = code_block.longest_line
        if code.width == 'block' then
            win_col = win_col - str.width(icon_text)
        end
        return self:add(true, info.start_row, 0, {
            virt_text = { { icon_text, highlight } },
            virt_text_win_col = win_col,
        })
    else
        return false
    end
end

---@private
---@param code_block render.md.parsed.CodeBlock
---@param icon_added boolean
function Handler:code_background(code_block, icon_added)
    local code = self.config.code

    if code.border == 'thin' then
        local border_width = code_block.width - code_block.col
        if not icon_added and code_block.code_info_hidden and code_block.start_delim_hidden then
            self:add(true, code_block.start_row, code_block.col, {
                virt_text = { { code.above:rep(border_width), colors.inverse(code.highlight) } },
                virt_text_pos = 'overlay',
            })
            code_block.start_row = code_block.start_row + 1
        end
        if code_block.end_delim_hidden then
            self:add(true, code_block.end_row - 1, code_block.col, {
                virt_text = { { code.below:rep(border_width), colors.inverse(code.highlight) } },
                virt_text_pos = 'overlay',
            })
            code_block.end_row = code_block.end_row - 1
        end
    end

    self:add(false, code_block.start_row, 0, {
        end_row = code_block.end_row,
        end_col = 0,
        hl_group = code.highlight,
        hl_eol = true,
    })

    if code.width == 'block' then
        -- Overwrite anything beyond width with Normal
        local padding = str.pad(vim.o.columns * 2)
        for row = code_block.start_row, code_block.end_row - 1 do
            self:add(false, row, 0, {
                priority = 0,
                virt_text = { { padding, 'Normal' } },
                virt_text_win_col = code_block.width,
            })
        end
    end
end

---@private
---@param code_block render.md.parsed.CodeBlock
---@param add_background boolean
function Handler:code_left_pad(code_block, add_background)
    local code = self.config.code
    if code.left_pad <= 0 then
        return
    end
    local padding = str.pad(code.left_pad)
    local highlight
    if add_background then
        highlight = code.highlight
    else
        highlight = 'Normal'
    end
    for row = code_block.start_row, code_block.end_row - 1 do
        -- Uses a low priority so other marks are loaded first and included in padding
        self:add(false, row, code_block.col, {
            priority = 0,
            virt_text = { { padding, highlight } },
            virt_text_pos = 'inline',
        })
    end
end

---@private
---@param info render.md.NodeInfo
function Handler:list_marker(info)
    ---@return boolean
    local function sibling_checkbox()
        if not self.config.checkbox.enabled then
            return false
        end
        if info:sibling('task_list_marker_unchecked') ~= nil then
            return true
        end
        if info:sibling('task_list_marker_checked') ~= nil then
            return true
        end
        local paragraph = info:sibling('paragraph')
        if paragraph == nil then
            return false
        end
        return component.checkbox(self.config, paragraph.text, 'starts') ~= nil
    end
    if sibling_checkbox() then
        -- Hide the list marker for checkboxes rather than replacing with a bullet point
        self:add(true, info.start_row, info.start_col, {
            end_row = info.end_row,
            end_col = info.end_col,
            conceal = '',
        })
    else
        local bullet = self.config.bullet
        if not bullet.enabled then
            return
        end
        local level = info:level_in_section('list')
        local icon = list.cycle(bullet.icons, level)
        if icon == nil then
            return
        end
        -- List markers from tree-sitter should have leading spaces removed, however there are known
        -- edge cases in the parser: https://github.com/tree-sitter-grammars/tree-sitter-markdown/issues/127
        -- As a result we handle leading spaces here, can remove if this gets fixed upstream
        local leading_spaces = str.leading_spaces(info.text)
        self:add(true, info.start_row, info.start_col, {
            end_row = info.end_row,
            end_col = info.end_col,
            virt_text = { { str.pad(leading_spaces, icon), bullet.highlight } },
            virt_text_pos = 'overlay',
        })
        if bullet.left_pad > 0 then
            self:add(false, info.start_row, 0, {
                priority = 0,
                virt_text = { { str.pad(bullet.left_pad), 'Normal' } },
                virt_text_pos = 'inline',
            })
        end
        if bullet.right_pad > 0 then
            self:add(true, info.start_row, info.end_col - 1, {
                virt_text = { { str.pad(bullet.right_pad), 'Normal' } },
                virt_text_pos = 'inline',
            })
        end
    end
end

---@private
---@param info render.md.NodeInfo
---@param checkbox_state render.md.CheckboxComponent
function Handler:checkbox(info, checkbox_state)
    if not self.config.checkbox.enabled then
        return
    end
    self:add(true, info.start_row, info.start_col, {
        end_row = info.end_row,
        end_col = info.end_col,
        virt_text = { { str.pad_to(info.text, checkbox_state.icon), checkbox_state.highlight } },
        virt_text_pos = 'overlay',
    })
end

---@private
---@param info render.md.NodeInfo
---@param block_quote render.md.NodeInfo
function Handler:quote_marker(info, block_quote)
    local quote = self.config.quote
    if not quote.enabled then
        return
    end
    local highlight = quote.highlight
    local callout = component.callout(self.config, block_quote.text, 'contains')
    if callout ~= nil then
        highlight = callout.highlight
    end
    self:add(true, info.start_row, info.start_col, {
        end_row = info.end_row,
        end_col = info.end_col,
        virt_text = { { info.text:gsub('>', quote.icon), highlight } },
        virt_text_pos = 'overlay',
        virt_text_repeat_linebreak = quote.repeat_linebreak or nil,
    })
end

---@private
---@param info render.md.NodeInfo
---@param text? string
---@param highlight string
function Handler:sign(info, text, highlight)
    local sign = self.config.sign
    if not sign.enabled or text == nil then
        return
    end
    self:add(false, info.start_row, info.start_col, {
        end_row = info.end_row,
        end_col = info.end_col,
        sign_text = text,
        sign_hl_group = colors.combine(highlight, sign.highlight),
    })
end

---@private
---@param info render.md.NodeInfo
function Handler:pipe_table(info)
    local pipe_table = self.config.pipe_table
    if not pipe_table.enabled or pipe_table.style == 'none' then
        return
    end
    local parsed_table = pipe_table_parser.parse(info)
    if parsed_table == nil then
        return
    end

    self:table_row(parsed_table.head, pipe_table.head)
    self:table_delimiter(parsed_table.delim, parsed_table.columns)
    for _, row in ipairs(parsed_table.rows) do
        self:table_row(row, pipe_table.row)
    end
    if pipe_table.style == 'full' then
        self:table_full(parsed_table)
    end
end

---@private
---@param row render.md.NodeInfo
---@param columns render.md.parsed.TableColumn[]
function Handler:table_delimiter(row, columns)
    local pipe_table = self.config.pipe_table
    local indicator = pipe_table.alignment_indicator
    local border = pipe_table.border
    local sections = vim.tbl_map(
        ---@param column render.md.parsed.TableColumn
        ---@return string
        function(column)
            -- If column is small there's no good place to put the alignment indicator
            -- Alignment indicator must be exactly one character wide
            -- We do not put an indicator for default alignment
            if column.width < 4 or str.width(indicator) ~= 1 or column.alignment == 'default' then
                return border[11]:rep(column.width)
            end
            -- Handle the various alignmnet possibilities
            local left = border[11]:rep(math.floor(column.width / 2))
            local right = border[11]:rep(math.ceil(column.width / 2) - 1)
            if column.alignment == 'left' then
                return indicator .. left .. right
            elseif column.alignment == 'right' then
                return left .. right .. indicator
            else
                return left .. indicator .. right
            end
        end,
        columns
    )
    local delimiter = border[4] .. table.concat(sections, border[5]) .. border[6]
    self:add(true, row.start_row, row.start_col, {
        end_row = row.end_row,
        end_col = row.end_col,
        virt_text = { { delimiter, pipe_table.head } },
        virt_text_pos = 'overlay',
    })
end

---@private
---@param row render.md.NodeInfo
---@param highlight string
function Handler:table_row(row, highlight)
    local pipe_table = self.config.pipe_table
    if vim.tbl_contains({ 'raw', 'padded' }, pipe_table.cell) then
        row:for_each_child(function(cell)
            if cell.type == '|' then
                self:add(true, cell.start_row, cell.start_col, {
                    end_row = cell.end_row,
                    end_col = cell.end_col,
                    virt_text = { { pipe_table.border[10], highlight } },
                    virt_text_pos = 'overlay',
                })
            elseif cell.type == 'pipe_table_cell' then
                if pipe_table.cell == 'padded' then
                    local offset = self:table_visual_offset(cell)
                    if offset > 0 then
                        self:add(true, cell.start_row, cell.end_col - 1, {
                            virt_text = { { str.pad(offset), pipe_table.filler } },
                            virt_text_pos = 'inline',
                        })
                    end
                end
            else
                logger.unhandled_type('markdown', 'cell', cell.type)
            end
        end)
    elseif pipe_table.cell == 'overlay' then
        self:add(true, row.start_row, row.start_col, {
            end_row = row.end_row,
            end_col = row.end_col,
            virt_text = { { row.text:gsub('|', pipe_table.border[10]), highlight } },
            virt_text_pos = 'overlay',
        })
    end
end

---@private
---@param parsed_table render.md.parsed.PipeTable
function Handler:table_full(parsed_table)
    local pipe_table = self.config.pipe_table
    local border = pipe_table.border

    ---@param info render.md.NodeInfo
    ---@return integer
    local function width(info)
        local result = str.width(info.text)
        if pipe_table.cell == 'raw' then
            -- For the raw cell style we want the lengths to match after
            -- concealing & inlined elements
            result = result - self:table_visual_offset(info)
        end
        return result
    end

    local first = parsed_table.head
    local last = parsed_table.rows[#parsed_table.rows]

    -- Do not need to account for concealed / inlined text on delimiter row
    local delim_width = str.width(parsed_table.delim.text)
    if delim_width ~= width(first) or delim_width ~= width(last) then
        return {}
    end

    local sections = vim.tbl_map(
        ---@param column render.md.parsed.TableColumn
        ---@return string
        function(column)
            return border[11]:rep(column.width)
        end,
        parsed_table.columns
    )

    local line_above = border[1] .. table.concat(sections, border[2]) .. border[3]
    self:add(false, first.start_row, first.start_col, {
        virt_lines_above = true,
        virt_lines = { { { line_above, pipe_table.head } } },
    })

    local line_below = border[7] .. table.concat(sections, border[8]) .. border[9]
    self:add(false, last.start_row, last.start_col, {
        virt_lines_above = false,
        virt_lines = { { { line_below, pipe_table.row } } },
    })
end

---@private
---@param info render.md.NodeInfo
---@return integer
function Handler:table_visual_offset(info)
    return self.context:concealed(info) - self.context:link_width(info)
end

---@class render.md.handler.Markdown: render.md.Handler
local M = {}

---@param root TSNode
---@param buf integer
---@return render.md.Mark[]
function M.parse(root, buf)
    return Handler.new(buf):parse(root)
end

return M
