@tool
class_name DotWeatherConfig
extends DotConfig

## What a player and an operator get to say about weather.
##
## [member allow_flashes] and [member flash_scale] are accessibility settings, not preferences:
## lightning is a full-screen brightness change, and a player who asked for none must get none.
## Fog is deliberately not here: it is the world's atmosphere and part of how far anyone can see,
## so letting one player turn it off would be an advantage (see docs/design.md).

@export_group("Quality")

## 0 off (no precipitation, no flashes, no bolt; the schedule, wind and signals still run), 1 low
## (a third of the flakes, no bolt), 2 high.
@export_range(0, 2, 1) var quality: int = 2

## Multiplies the thickness of precipitation, 0 to 2. A player's slider.
@export_range(0.0, 2.0, 0.05) var density_scale: float = 1.0

@export_group("Accessibility")

## Whether lightning brightens the sky and ambient light at all. Thunder still arrives.
@export var allow_flashes: bool = true

## Multiplies the flash brightness, 0 to 1. Zero is the same as [member allow_flashes] off.
@export_range(0.0, 1.0, 0.05) var flash_scale: float = 1.0


func env_prefix() -> String:
	return "DOT_WEATHER_"


func cli_prefix() -> String:
	return "--weather-"


func validate() -> DotResult:
	if quality < 0 or quality > 2:
		return DotResult.fail(DotError.CODE_INVALID, "quality is a tier from 0 to 2")
	return DotResult.success(null)
