local barSize = UDim.new(0.02075, 0)
--First number is size in scale (percent) and second number is size in offset (pixels)

local scrollingFrame = script.Parent
local scrollingFrameParent = script.Parent.Parent

local function update()
	scrollingFrame.ScrollBarThickness = scrollingFrameParent.AbsoluteSize.X * barSize.Scale + barSize.Offset
end

update()
scrollingFrameParent:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)