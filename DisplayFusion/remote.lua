local kb = libs.keyboard;


-- Documentation
-- http://www.unifiedremote.com/api

-- Keyboard Library
-- http://www.unifiedremote.com/api/libs/keyboard


--@help Select Next Playback Device
actions.selectnextplayback = function ()
	kb.stroke("ctrl", "alt", "shift", "a");
end


--@help Profile Main + Top
actions.profile0 = function ()
	kb.stroke("ctrl", "alt", "shift", "0");
end


--@help Profile Main
actions.profile1 = function ()
	kb.stroke("ctrl", "alt", "shift", "1");
end


--@help Profile Top
actions.profile2 = function ()
	kb.stroke("ctrl", "alt", "shift", "2");
end


--@help Profile TV
actions.profile3 = function ()
	kb.stroke("ctrl", "alt", "shift", "3");
end


--@help Profile TV + Top
actions.profile4 = function ()
	kb.stroke("ctrl", "alt", "shift", "4");
end


--@help Profile Main + Top + TV
actions.profile5 = function ()
	kb.stroke("ctrl", "alt", "shift", "5");
end