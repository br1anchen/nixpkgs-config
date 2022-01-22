#!/bin/bash

# Terminate already running bar instances
killall -q polybar

polybar --reload main &
