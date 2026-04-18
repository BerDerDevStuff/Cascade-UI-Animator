--!strict

export type Keyframe = {
	Time: number, 
	Value: any, 
	Easing: Enum.EasingStyle?, 
	Direction: Enum.EasingDirection? 
}

export type ProcessedTrack = { 
	SubPath: {string}, 
	Keyframes: {Keyframe}, 
	IsRelative: boolean, 
	RawPath: string, 
	InstancePath: {string} 
}


export type AnimationEvent = {
	Time: number,
	Name: string,
	DataType: string?,
	Data: any?
}
export type AnimationConfig = { 
	Length: number, 
	Loop: (boolean | number)?, 
	Delay: number?, 
	Tracks: { [string]: { Keyframe } },
	Settings: { [string]: any }?,
	Events: {AnimationEvent}?
}

export type ProcessedAnimation = { 
	IsProcessed: boolean, 
	Length: number, 
	Loop: boolean | number, 
	Delay: number, 
	PropertyGroups: { [string]: { ProcessedTrack } },
	Events: {AnimationEvent}?
}

export type TrackOptions = { 
	Delay: number?, 
	Loop: (boolean | number)?, 
	Stagger: number?, 
	Reset: boolean?,        
	ResetToStart: boolean?,
	Reverse: boolean?,
	DeleteOnComplete: boolean?,
}

export type ActiveTrack = {
	Data: ProcessedTrack,
	Target: Instance,
	BaseProp: string, 
	Setter: (any) -> (),    
	BaseValue: any,        
	Cursor: number,
	CurrentLerp: ((number) -> any)? 
}

export type AnimTrack = {
	Instance: Instance,
	State: "Playing" | "Paused" | "Suspended",
	CurrentTime: number,
	Speed: number,
	AutoDestroy: boolean,
	IsDestroyed: boolean,

	Completed: { Connect: (any, any) -> any, Destroy: (any) -> () },
	Looped: { Connect: (any, any) -> any, Destroy: (any) -> () },
	Cancelled: { Connect: (any, any) -> any, Destroy: (any) -> () },
	MarkerReached: { Connect: (any, any) -> any, Destroy: (any) -> () },

	Play: (self: AnimTrack) -> (),
	Pause: (self: AnimTrack) -> (),
	Suspend: (self: AnimTrack) -> (),
	Stop: (self: AnimTrack) -> (),
	Scrub: (self: AnimTrack, time: number) -> (),
	SetSpeed: (self: AnimTrack, speed: number) -> (),
	SetLoop: (self: AnimTrack, loop: boolean | number) -> (),
	InvalidateBaseState: (self: AnimTrack) -> (),
	Destroy: (self: AnimTrack) -> (),

	Contains: (self: AnimTrack, instance: Instance) -> boolean,
	IsValid: (self: AnimTrack) -> boolean,
	Prune: (self: AnimTrack, instance: Instance) -> (),

	_Update: (self: AnimTrack, now: number) -> { [Instance]: { [string]: any } }?
}

export type BatchedAnimTrack = {
	Instances: {Instance},
	State: "Playing" | "Paused" | "Suspended",
	CurrentTime: number,
	Speed: number,
	AutoDestroy: boolean,
	IsDestroyed: boolean,

	Completed: { Connect: (any, any) -> any, Destroy: (any) -> () },
	Looped: { Connect: (any, any) -> any, Destroy: (any) -> () },
	Cancelled: { Connect: (any, any) -> any, Destroy: (any) -> () },
	MarkerReached: { Connect: (any, any) -> any, Destroy: (any) -> () },

	Play: (self: BatchedAnimTrack) -> (),
	Pause: (self: BatchedAnimTrack) -> (),
	Suspend: (self: BatchedAnimTrack) -> (),
	Stop: (self: BatchedAnimTrack) -> (),
	Scrub: (self: BatchedAnimTrack, time: number) -> (),
	SetSpeed: (self: BatchedAnimTrack, speed: number) -> (),
	SetLoop: (self: BatchedAnimTrack, loop: boolean | number) -> (),
	SetStagger: (self: BatchedAnimTrack, stagger: number) -> (),
	InvalidateBaseState: (self: BatchedAnimTrack) -> (),
	Destroy: (self: BatchedAnimTrack) -> (),

	Contains: (self: BatchedAnimTrack, instance: Instance) -> boolean,
	IsValid: (self: BatchedAnimTrack) -> boolean,
	Prune: (self: BatchedAnimTrack, instance: Instance) -> (),

	_Update: (self: BatchedAnimTrack, now: number) -> { [Instance]: { [string]: any } }?
}

return nil