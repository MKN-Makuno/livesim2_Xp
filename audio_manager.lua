-- Audio management system
-- Part of Live Simulator: 2
-- See copyright notice in main.lua

-- The audio manager can be tuned either to
-- output the audio directly to OpenAL or
-- manually mixing the audio. Audio manager
-- mix audio automatically in 48000Hz sample
-- rate

local love = require("love")
local ls2x = require("libs.ls2x")

local lily = require("lily")
local log = require("logging")
local Cache = require("cache")
local Async = require("async")
local Util = require("util")
local Volume = require("volume")

local ffi

local AudioManager = {
	renderRate = 0, -- not rendering
	samplesPerFrame = 0,
	tempBuffer = nil,
	playing = {}
}

-- must be called before any audio is loaded or the behaviour is undefined
---@param rate integer
function AudioManager.setRenderFramerate(rate)
	if rate > 0 then
		local smpPerFrame = 48000/rate
		ffi = require("ffi")
		assert(ls2x.audiomix, "audiomix feature is unavailable")
		assert(smpPerFrame % 1 == 0, "cannot use specified framerate (48000 is not divisible by rate)")
		assert(ls2x.audiomix.startSession(Volume.get("master"), 48000, smpPerFrame), "cannot start session")
		AudioManager.tempBuffer = ffi.new("short[?]", smpPerFrame * 2) -- for looping (emulate ringbuffer)
		AudioManager.renderRate = rate
		AudioManager.samplesPerFrame = smpPerFrame
	elseif rate == 0 and AudioManager.renderRate > 0 then
		ls2x.audiomix.endSession()
		AudioManager.tempBuffer = nil
		AudioManager.renderRate = nil
		AudioManager.samplesPerFrame = nil
	end
end

function AudioManager.updateRender()
	assert(AudioManager.renderRate > 0, "not in render mode")

	for i = #AudioManager.playing, 1, -1 do
		local obj = AudioManager.playing[i]

		if obj.pos + AudioManager.samplesPerFrame >= obj.size and obj.looping then
			-- use temporary buffer for copying
			local remain = obj.size - obj.pos
			-- copy almost eof buffer
			ffi.copy(
				AudioManager.tempBuffer,
				obj.soundDataPointer + remain * obj.channelCount,
				remain * 2 * obj.channelCount
			)
			obj.pos = (obj.pos + AudioManager.samplesPerFrame) % obj.size
			-- copy start buffer
			ffi.copy(
				AudioManager.tempBuffer + remain * obj.channelCount,
				obj.soundDataPointer,
				obj.pos * 2 * obj.channelCount
			)
			if obj.volume > 0 then
				-- mix
				ls2x.audiomix.mixSample(
					AudioManager.tempBuffer,
					AudioManager.samplesPerFrame,
					obj.channelCount,
					obj.volume
				)
			end
		else
			-- just mix
			if obj.volume > 0 then
				ls2x.audiomix.mixSample(
					obj.soundDataPointer + obj.pos * obj.channelCount,
					math.min(AudioManager.samplesPerFrame, obj.size - obj.pos),
					obj.channelCount,
					obj.volume
				)
			end
			obj.pos = math.min(obj.size, obj.pos + AudioManager.samplesPerFrame)

			if obj.pos >= obj.size then
				-- stop playback
				obj.pos = 0
				obj.playing = false
				table.remove(AudioManager.playing, i)
			end
		end
	end

	-- get buffer
	local sound = love.sound.newSoundData(AudioManager.samplesPerFrame, 48000, 16, 2)
	ls2x.audiomix.getSample(ffi.cast("short*", sound:getPointer()))
	return sound
end

function AudioManager.newAudio(path, kind)
	if type(path) == "string" then
		log.debugf("audioManager", "loading audio %s", path)
		local sd = Cache.get(path)
		if not(sd) then
			local sdAsync = Async.syncLily(lily.newSoundData(path))
			sd = sdAsync:getValues() -- automatically sync
			Cache.set(path, sd)
		end

		return AudioManager.newAudioDirect(sd, kind)
	else
		return AudioManager.newAudioDirect(path, kind)
	end
end

---@param data love.SoundData|love.Decoder|love.Data|love.File
---@param kind string
---@return livesim2.AudioManager.Object
function AudioManager.newAudioDirect(data, kind)
	---@class livesim2.AudioManager.Object
	local obj = {
		pos = 0,
		size = 0,
		volume = Volume.get(kind),
		volumeKind = kind,
		playing = false,
		looping = false,
		---@type love.SoundData|nil
		soundData = nil,
		soundDataPointer = nil,
		---@type love.SoundData|nil
		originalSoundData = nil,
		---@type integer
		channelCount = nil,
		---@type love.Source
		source = nil,
	}
	if AudioManager.renderRate > 0 then
		-- render mode requires 48000Hz
		if Util.isLOVEType(data) and not Util.isLOVEType(data, "SoundData") then
			local sdAsync = Async.syncLily(lily.newSoundData(data))
			data = sdAsync:getValues() -- automatically sync
		end

		---@cast data love.SoundData
		obj.channelCount = Util.getChannelCount(data)

		-- check sample rate
		if data:getSampleRate() ~= 48000 then
			log.debugf("audioManager", "sample rate %d ~= 48000, resampling", data:getSampleRate())
			log.debugf("audioManager", "audio duration=%.2f, channel=%d",
				data:getSampleCount() / data:getSampleRate(),
				obj.channelCount
			)
			-- new sound data for resample
			local len = math.ceil(48000 * data:getSampleCount() / data:getSampleRate())
			local data2 = love.sound.newSoundData(len, 48000, 16, obj.channelCount)
			ls2x.audiomix.resample(
				ffi.cast("short*", data:getPointer()),
				ffi.cast("short*", data2:getPointer()),
				data:getSampleCount(), len, obj.channelCount
			)
			obj.originalSoundData = data
			data = data2
		end

		-- populate object
		obj.size = data:getSampleCount()
		obj.soundData = data
		obj.soundDataPointer = ffi.cast("short*", data:getPointer())
		return obj
	else
		if Util.isLOVEType(data, "SoundData") then
			---@cast data love.SoundData
			obj.soundData = data
			obj.source = love.audio.newSource(data)
		else
			-- just new source
			obj.source = love.audio.newSource(data, "static")
		end
		obj.source:setVolume(obj.volume)
		return obj
	end
end

---@param obj livesim2.AudioManager.Object
function AudioManager.clone(obj)
	---@class livesim2.AudioManager.Object
	local x = {
		pos = 0,
		size = obj.size,
		volume = obj.volume,
		volumeKind = obj.volumeKind,
		playing = false,
		looping = false,
		soundData = obj.soundData,
		soundDataPointer = obj.soundDataPointer,
		originalSoundData = obj.originalSoundData,
		channelCount = obj.channelCount,
		source = obj.source,
	}
	if x.source then x.source = x.source:clone() end

	return x
end

---@param obj livesim2.AudioManager.Object
function AudioManager.play(obj)
	if AudioManager.renderRate > 0 then
		if obj.playing then return end
		AudioManager.playing[#AudioManager.playing + 1] = obj
		obj.playing = true
	else
		return obj.source:play()
	end
end

---@param obj livesim2.AudioManager.Object
function AudioManager.pause(obj)
	if AudioManager.renderRate > 0 then
		if not(obj.playing) then return end

		for i = 1, #AudioManager.playing do
			if AudioManager.playing[i] == obj then
				table.remove(AudioManager.playing, i)
				obj.playing = false
				return
			end
		end
	else
		return obj.source:pause()
	end
end

---@param obj livesim2.AudioManager.Object
function AudioManager.stop(obj)
	if AudioManager.renderRate > 0 then
		AudioManager.pause(obj)
		obj.pos = 0
	else
		return obj.source:stop()
	end
end

---@param obj livesim2.AudioManager.Object
function AudioManager.isLooping(obj)
	if AudioManager.renderRate > 0 then
		return obj.looping
	else
		return obj.source:isLooping()
	end
end

---@param obj livesim2.AudioManager.Object
function AudioManager.setLooping(obj, loop)
	if AudioManager.renderRate > 0 then
		obj.looping = loop
	else
		obj.source:setLooping(loop)
	end
end

---@param obj livesim2.AudioManager.Object
function AudioManager.isPlaying(obj)
	if AudioManager.renderRate > 0 then
		return obj.playing
	else
		return obj.source:isPlaying()
	end
end

---@param obj livesim2.AudioManager.Object
---@param vol number
function AudioManager.setVolume(obj, vol)
	vol = Volume.get(obj.volumeKind, vol)
	if AudioManager.renderRate > 0 then
		obj.volume = vol
	else
		return obj.source:setVolume(vol)
	end
end

---@param obj livesim2.AudioManager.Object
---@param seconds number
function AudioManager.seek(obj, seconds)
	if AudioManager.renderRate > 0 then
		obj.pos = 48000 * seconds
	else
		return obj.source:seek(seconds, "seconds")
	end
end

function AudioManager.isRenderMode()
	return AudioManager.renderRate > 0
end

return AudioManager
