-- BGM management
-- Part of Live Simulator: 2
-- See copyright notice in main.lua

local Luaoop = require("libs.Luaoop")

local AudioManager = require("audio_manager")
local Util = require("util")

local BGM = {}
---@class livesim2.BGM
local BGMClass = Luaoop.class("livesim2.BGM")

---@param sd love.SoundData|love.Decoder|love.Data|love.File
function BGMClass:__construct(sd)
	if not(sd:typeOf("SoundData")) then
		sd = love.sound.newSoundData(sd)
	end

	---@cast sd love.SoundData
	self.audio = AudioManager.newAudioDirect(sd, "music")
	self.channel = Util.getChannelCount(sd)
	self.soundData = sd
end

function BGMClass:play()
	return AudioManager.play(self.audio)
end

function BGMClass:pause()
	return AudioManager.pause(self.audio)
end

function BGMClass:rewind()
	AudioManager.stop(self.audio)
	return AudioManager.play(self.audio)
end

---@param sd love.SoundData
---@param pos integer
function BGMClass._getSampleSafe(sd, pos)
	local s, v = pcall(sd.getSample, sd, pos)
	return s and v or 0
end

---@param output number[]
---@param sd love.SoundData
---@param pos integer
---@param amount integer
function BGMClass:_populateSample(output, sd, pos, amount)
	if self.channel == 1 then
		-- mono
		for i = 1, amount do
			local smp = BGMClass._getSampleSafe(sd, pos + i - 1)
			output[i * 2 - 1], output[i * 2 - 0] = smp, smp
		end
	else
		-- stereo
		for i = 1, amount do
			local x = pos + i - 1
			output[i * 2 - 1] = BGMClass._getSampleSafe(sd, x * 2)
			output[i * 2 - 0] = BGMClass._getSampleSafe(sd, x * 2 + 1)
		end
	end
end

---@param output number[]
---@param amount integer
function BGMClass:_getSamplesRender(output, amount)
	-- Use original sound data
	local sd, pos
	if self.audio.originalSoundData then
		-- Do position conversion
		sd = self.audio.originalSoundData
		pos = math.floor(sd:getSampleRate() * self.audio.pos / 48000 + 0.5)
	else
		sd = self.audio.soundData
		pos = self.audio.pos
	end

	return self:_populateSample(output, sd, pos, amount)
end

-- interleaved samples: {l, r, l, r, l, r, ...}
---@param amount integer
---@return number[]
function BGMClass:getSamples(amount)
	local output = {}
	if AudioManager.renderRate > 0 then
		self:_getSamplesRender(output, amount)
	else
		self:_populateSample(output, self.soundData, self.audio.source:tell("samples"), amount)
	end

	return output
end

---@param timepos number
function BGMClass:seek(timepos)
	return AudioManager.seek(self.audio, timepos)
end

function BGMClass:tell()
	if AudioManager.renderRate > 0 then
		return self.audio.pos / 48000
	else
		return self.audio.source:tell()
	end
end

function BGMClass:isPlaying()
	return AudioManager.isPlaying(self.audio)
end

function BGMClass:getSampleRate()
	if AudioManager.renderRate > 0 then
		return 48000
	else
		return self.soundData:getSampleRate()
	end
end

---@param decoder love.FileData|love.File|string
---@return livesim2.BGM
function BGM.newSong(decoder)
	return BGMClass(Util.newDecoder(decoder))
end

return BGM
