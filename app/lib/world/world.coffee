Vector = require './vector'
Rectangle = require './rectangle'
Ellipse = require './ellipse'
LineSegment = require './line_segment'
WorldFrame = require './world_frame'
Thang = require './thang'
ThangState = require './thang_state'
Rand = require './rand'
WorldScriptNote = require './world_script_note'
{now, consolidateThangs, typedArraySupport} = require './world_utils'
Component = require 'lib/world/component'
System = require 'lib/world/system'
PROGRESS_UPDATE_INTERVAL = 100
DESERIALIZATION_INTERVAL = 10
REAL_TIME_BUFFER_MIN = 2 * PROGRESS_UPDATE_INTERVAL
REAL_TIME_BUFFER_MAX = 3 * PROGRESS_UPDATE_INTERVAL
REAL_TIME_BUFFERED_WAIT_INTERVAL = 0.5 * PROGRESS_UPDATE_INTERVAL
REAL_TIME_COUNTDOWN_DELAY = 3000  # match CountdownScreen
ITEM_ORIGINAL = '53e12043b82921000051cdf9'

module.exports = class World
  @className: 'World'
  age: 0
  ended: false
  preloading: false  # Whether we are just preloading a world in case we soon cast it
  debugging: false  # Whether we are just rerunning to debug a world we've already cast
  headless: false  # Whether we are just simulating for goal states instead of all serialized results
  framesSerializedSoFar: 0
  apiProperties: ['age', 'dt']
  realTimeBufferMax: REAL_TIME_BUFFER_MAX / 1000
  constructor: (@userCodeMap, classMap) ->
    # classMap is needed for deserializing Worlds, Thangs, and other classes
    @classMap = classMap ? {Vector: Vector, Rectangle: Rectangle, Thang: Thang, Ellipse: Ellipse, LineSegment: LineSegment}
    Thang.resetThangIDs()

    @userCodeMap ?= {}
    @thangs = []
    @thangMap = {}
    @systems = []
    @systemMap = {}
    @scriptNotes = []
    @flagHistory = []
    @rand = new Rand 0  # Existence System may change this seed
    @frames = [new WorldFrame(@, 0)]

  destroy: ->
    @goalManager?.destroy()
    thang.destroy() for thang in @thangs
    @[key] = undefined for key of @
    @destroyed = true
    @destroy = ->

  getFrame: (frameIndex) ->
    # Optimize it a bit--assume we have all if @ended and are at the previous frame otherwise
    frames = @frames
    if @ended
      frame = frames[frameIndex]
    else if frameIndex
      frame = frames[frameIndex - 1].getNextFrame()
      frames.push frame
    else
      frame = frames[0]
    @age = frameIndex * @dt
    frame

  getThangByID: (id) ->
    @thangMap[id]

  setThang: (thang) ->
    for old, i in @thangs
      console.error 'world trying to set', thang, 'over', old unless old? and thang?
      if old.id is thang.id
        @thangs[i] = thang
    @thangMap[thang.id] = thang

  thangDialogueSounds: (startFrame=0) ->
    return [] unless startFrame < @frames.length
    [sounds, seen] = [[], {}]
    for frameIndex in [startFrame ... @frames.length]
      frame = @frames[frameIndex]
      for thangID, state of frame.thangStateMap
        continue unless state.thang.say and sayMessage = state.getStateForProp 'sayMessage'
        soundKey = state.thang.spriteName + ':' + sayMessage
        unless seen[soundKey]
          sounds.push [state.thang.spriteName, sayMessage]
          seen[soundKey] = true
    sounds

  setGoalManager: (@goalManager) ->

  addError: (error) ->
    (@runtimeErrors ?= []).push error
    (@unhandledRuntimeErrors ?= []).push error

  loadFrames: (loadedCallback, errorCallback, loadProgressCallback, preloadedCallback, skipDeferredLoading, loadUntilFrame) ->
    return if @aborted
    console.log 'Warning: loadFrames called on empty World (no thangs).' unless @thangs.length
    continueLaterFn = =>
      @loadFrames(loadedCallback, errorCallback, loadProgressCallback, preloadedCallback, skipDeferredLoading, loadUntilFrame) unless @destroyed
    if @realTime and not @countdownFinished
      if @levelID in ['the-first-kithmaze', 'the-second-kithmaze', 'the-final-kithmaze']
        @realTimeSpeedFactor = 3
      else
        @realTimeSpeedFactor = 1
      return setTimeout @finishCountdown(continueLaterFn), REAL_TIME_COUNTDOWN_DELAY
    t1 = now()
    @t0 ?= t1
    @worldLoadStartTime ?= t1
    @lastRealTimeUpdate ?= 0
    frameToLoadUntil = if loadUntilFrame then loadUntilFrame + 1 else @totalFrames  # Might stop early if debugging.
    i = @frames.length
    while i < frameToLoadUntil and i < @totalFrames
      return unless @shouldContinueLoading t1, loadProgressCallback, skipDeferredLoading, continueLaterFn
      @adjustFlowSettings loadUntilFrame if @debugging
      try
        @getFrame(i)
        ++i  # Increment this after we have succeeded in getting the frame, otherwise we'll have to do that frame again
      catch error
        @addError error  # Not an Aether.errors.UserCodeError; maybe we can't recover
      unless @preloading or @debugging
        for error in (@unhandledRuntimeErrors ? [])
          return unless errorCallback error  # errorCallback tells us whether the error is recoverable
        @unhandledRuntimeErrors = []
    @finishLoadingFrames loadProgressCallback, loadedCallback, preloadedCallback

  finishLoadingFrames: (loadProgressCallback, loadedCallback, preloadedCallback) ->
    unless @debugging
      @ended = true
      system.finish @thangs for system in @systems
    if @preloading
      preloadedCallback()
    else
      loadProgressCallback? 1
      loadedCallback()

  finishCountdown: (continueLaterFn) -> =>
    return if @destroyed
    @countdownFinished = true
    continueLaterFn()

  shouldDelayRealTimeSimulation: (t) ->
    return false unless @realTime
    timeSinceStart = (t - @worldLoadStartTime) * @realTimeSpeedFactor
    timeLoaded = @frames.length * @dt * 1000
    timeBuffered = timeLoaded - timeSinceStart
    timeBuffered > REAL_TIME_BUFFER_MAX * @realTimeSpeedFactor

  shouldUpdateRealTimePlayback: (t) ->
    return false unless @realTime
    return false if @frames.length * @dt is @lastRealTimeUpdate
    timeLoaded = @frames.length * @dt * 1000
    timeSinceStart = (t - @worldLoadStartTime) * @realTimeSpeedFactor
    remainingBuffer = @lastRealTimeUpdate * 1000 - timeSinceStart
    remainingBuffer < REAL_TIME_BUFFER_MIN * @realTimeSpeedFactor

  shouldContinueLoading: (t1, loadProgressCallback, skipDeferredLoading, continueLaterFn) ->
    t2 = now()
    if @realTime
      shouldUpdateProgress = @shouldUpdateRealTimePlayback t2
      shouldDelayRealTimeSimulation = not shouldUpdateProgress and @shouldDelayRealTimeSimulation t2
    else
      shouldUpdateProgress = t2 - t1 > PROGRESS_UPDATE_INTERVAL
      shouldDelayRealTimeSimulation = false
    return true unless shouldUpdateProgress or shouldDelayRealTimeSimulation
    # Stop loading frames for now; continue in a moment.
    if shouldUpdateProgress
      @lastRealTimeUpdate = @frames.length * @dt if @realTime
      #console.log 'we think it is now', (t2 - @worldLoadStartTime) / 1000, 'so delivering', @lastRealTimeUpdate
      loadProgressCallback? @frames.length / @totalFrames unless @preloading
    t1 = t2
    if t2 - @t0 > 1000
      console.log '  Loaded', @frames.length, 'of', @totalFrames, '(+' + (t2 - @t0).toFixed(0) + 'ms)' unless @realTime
      @t0 = t2
    if skipDeferredLoading
      continueLaterFn()
    else
      delay = if shouldDelayRealTimeSimulation then REAL_TIME_BUFFERED_WAIT_INTERVAL else 0
      setTimeout continueLaterFn, delay
    false

  adjustFlowSettings: (loadUntilFrame) ->
    for thang in @thangs when thang.isProgrammable
      userCode = @userCodeMap[thang.id] ? {}
      for methodName, aether of userCode
        framesToLoadFlowBefore = if methodName is 'plan' or methodName is 'makeBid' then 200 else 1  # Adjust if plan() is taking even longer
        aether._shouldSkipFlow = @frames.length < loadUntilFrame - framesToLoadFlowBefore

  finalizePreload: (loadedCallback) ->
    @preloading = false
    loadedCallback() if @ended

  abort: ->
    @aborted = true

  addFlagEvent: (flagEvent) ->
    @flagHistory.push flagEvent

  loadFromLevel: (level, willSimulate=true) ->
    @levelID = level.slug
    @levelComponents = level.levelComponents
    @thangTypes = level.thangTypes
    @loadSystemsFromLevel level
    @loadThangsFromLevel level, willSimulate
    @loadScriptsFromLevel level
    system.start @thangs for system in @systems

  loadSystemsFromLevel: (level) ->
    # Remove old Systems
    @systems = []
    @systemMap = {}

    # Load new Systems
    for levelSystem in level.systems
      systemModel = levelSystem.model
      config = levelSystem.config
      systemClass = @loadClassFromCode systemModel.js, systemModel.name, 'system'
      #console.log "using db system class ---\n", systemClass, "\n--- from code ---n", systemModel.js, "\n---"
      system = new systemClass @, config
      @addSystems system
    null

  loadThangsFromLevel: (level, willSimulate) ->
    # Remove old Thangs
    @thangs = []
    @thangMap = {}

    # Load new Thangs
    toAdd = (@loadThangFromLevel thangConfig, level.levelComponents, level.thangTypes for thangConfig in level.thangs ? [])
    @extraneousThangs = consolidateThangs toAdd if willSimulate  # Combine walls, for example; serialize the leftovers later
    @addThang thang for thang in toAdd
    null

  loadThangFromLevel: (thangConfig, levelComponents, thangTypes, equipBy=null) ->
    components = []
    for component in thangConfig.components
      componentModel = _.find levelComponents, (c) ->
        c.original is component.original and c.version.major is (component.majorVersion ? 0)
      componentClass = @loadClassFromCode componentModel.js, componentModel.name, 'component'
      components.push [componentClass, component.config]
      if equipBy and component.original is ITEM_ORIGINAL
        component.config.ownerID = equipBy
    thangTypeOriginal = thangConfig.thangType
    thangTypeModel = _.find thangTypes, (t) -> t.original is thangTypeOriginal
    return console.error thangConfig.id ? equipBy, 'could not find ThangType for', thangTypeOriginal unless thangTypeModel
    thangTypeName = thangTypeModel.name
    thang = new Thang @, thangTypeName, thangConfig.id
    try
      thang.addComponents components...
    catch e
      console.error 'couldn\'t load components for', thangTypeOriginal, thangConfig.id, 'because', e.toString(), e.stack
    thang

  addThang: (thang) ->
    @thangs.unshift thang  # Interactions happen in reverse order of specification/drawing
    @setThang thang
    @updateThangState thang
    thang.updateRegistration()
    thang

  loadScriptsFromLevel: (level) ->
    @scriptNotes = []
    @scripts = []
    @addScripts level.scripts...

  loadClassFromCode: (js, name, kind='component') ->
    # Cache them based on source code so we don't have to worry about extra compilations
    @componentCodeClassMap ?= {}
    @systemCodeClassMap ?= {}
    map = if kind is 'component' then @componentCodeClassMap else @systemCodeClassMap
    c = map[js]
    return c if c
    try
      c = map[js] = eval js
    catch err
      console.error "Couldn't compile #{kind} code:", err, "\n", js
      c = map[js] = {}
    c.className = name
    c

  updateThangState: (thang) ->
    @frames[@frames.length-1].thangStateMap[thang.id] = thang.getState()

  size: ->
    @calculateBounds() unless @width? and @height?
    return [@width, @height] if @width? and @height?

  getBounds: ->
    @calculateBounds() unless @bounds?
    return @bounds

  calculateBounds: ->
    bounds = {left: 0, top: 0, right: 0, bottom: 0}
    hasLand = _.some @thangs, 'isLand'
    for thang in @thangs when thang.isLand or (not hasLand and thang.rectangle)  # Look at Lands only
      rect = thang.rectangle().axisAlignedBoundingBox()
      bounds.left = Math.min(bounds.left, rect.x - rect.width / 2)
      bounds.right = Math.max(bounds.right, rect.x + rect.width / 2)
      bounds.bottom = Math.min(bounds.bottom, rect.y - rect.height / 2)
      bounds.top = Math.max(bounds.top, rect.y + rect.height / 2)
    @width = bounds.right - bounds.left
    @height = bounds.top - bounds.bottom
    @bounds = bounds
    [@width, @height]

  publishNote: (channel, event) ->
    event ?= {}
    channel = 'world:' + channel
    for script in @scripts
      continue if script.channel isnt channel
      scriptNote = new WorldScriptNote script, event
      continue if scriptNote.invalid
      @scriptNotes.push scriptNote
    return unless @goalManager
    @goalManager.submitWorldGenerationEvent(channel, event, @frames.length)

  getGoalState: (goalID) ->
    @goalManager.getGoalState(goalID)

  setGoalState: (goalID, status) ->
    @goalManager.setGoalState(goalID, status)

  endWorld: (victory=false, delay=3, tentative=false) ->
    @totalFrames = Math.min(@totalFrames, @frames.length + Math.floor(delay / @dt))  # end a few seconds later
    @victory = victory  # TODO: should just make this signify the winning superteam
    @victoryIsTentative = tentative
    status = if @victory then 'won' else 'lost'
    @publishNote status
    console.log "The world ended in #{status} on frame #{@totalFrames}"

  addSystems: (systems...) ->
    @systems = @systems.concat systems
    for system in systems
      @systemMap[system.constructor.className] = system
  getSystem: (systemClassName) ->
    @systemMap?[systemClassName]

  addScripts: (scripts...) ->
    @scripts = (@scripts ? []).concat scripts

  addTrackedProperties: (props...) ->
    @trackedProperties = (@trackedProperties ? []).concat props

  serialize: ->
    # Code hotspot; optimize it
    startFrame = @framesSerializedSoFar
    endFrame = @frames.length
    #console.log "... world serializing frames from", startFrame, "to", endFrame, "of", @totalFrames
    [transferableObjects, nontransferableObjects] = [0, 0]
    o = {totalFrames: @totalFrames, maxTotalFrames: @maxTotalFrames, frameRate: @frameRate, dt: @dt, victory: @victory, userCodeMap: {}, trackedProperties: {}}
    o.trackedProperties[prop] = @[prop] for prop in @trackedProperties or []

    for thangID, methods of @userCodeMap
      serializedMethods = o.userCodeMap[thangID] = {}
      for methodName, method of methods
        serializedMethods[methodName] = method.serialize?() ? method # serialize the method again if it has been deserialized

    t0 = now()
    o.trackedPropertiesThangIDs = []
    o.trackedPropertiesPerThangIndices = []
    o.trackedPropertiesPerThangKeys = []
    o.trackedPropertiesPerThangTypes = []
    trackedPropertiesPerThangValues = []  # We won't send these, just the offsets and the storage buffer
    o.trackedPropertiesPerThangValuesOffsets = []  # Needed to reconstruct ArrayBufferViews on other end, since Firefox has bugs transfering those: https://bugzilla.mozilla.org/show_bug.cgi?id=841904 and https://bugzilla.mozilla.org/show_bug.cgi?id=861925  # Actually, as of January 2014, it should be fixed. So we could try to undo the workaround.
    transferableStorageBytesNeeded = 0
    nFrames = endFrame - startFrame
    streaming = nFrames < @totalFrames
    for thang in @thangs
      # Don't serialize empty trackedProperties for stateless Thangs which haven't changed (like obstacles).
      # Check both, since sometimes people mark stateless Thangs but then change them, and those should still be tracked, and the inverse doesn't work on the other end (we'll just think it doesn't exist then).
      # If streaming the world, a thang marked stateless that actually change will get messed up. I think.
      continue if thang.stateless and not _.some(thang.trackedPropertiesUsed, Boolean)
      o.trackedPropertiesThangIDs.push thang.id
      trackedPropertiesIndices = []
      trackedPropertiesKeys = []
      trackedPropertiesTypes = []
      for used, propIndex in thang.trackedPropertiesUsed
        continue unless used
        trackedPropertiesIndices.push propIndex
        trackedPropertiesKeys.push thang.trackedPropertiesKeys[propIndex]
        trackedPropertiesTypes.push thang.trackedPropertiesTypes[propIndex]
      o.trackedPropertiesPerThangIndices.push trackedPropertiesIndices
      o.trackedPropertiesPerThangKeys.push trackedPropertiesKeys
      o.trackedPropertiesPerThangTypes.push trackedPropertiesTypes
      trackedPropertiesPerThangValues.push []
      o.trackedPropertiesPerThangValuesOffsets.push []
      for type in trackedPropertiesTypes
        transferableStorageBytesNeeded += ThangState.transferableBytesNeededForType(type, nFrames)
    if typedArraySupport
      o.storageBuffer = new ArrayBuffer(transferableStorageBytesNeeded)
    else
      o.storageBuffer = []
    storageBufferOffset = 0
    for trackedPropertiesValues, thangIndex in trackedPropertiesPerThangValues
      trackedPropertiesValuesOffsets = o.trackedPropertiesPerThangValuesOffsets[thangIndex]
      for type, propIndex in o.trackedPropertiesPerThangTypes[thangIndex]
        [storage, bytesStored] = ThangState.createArrayForType type, nFrames, o.storageBuffer, storageBufferOffset
        trackedPropertiesValues.push storage
        trackedPropertiesValuesOffsets.push storageBufferOffset
        ++transferableObjects if bytesStored
        ++nontransferableObjects unless bytesStored
        if typedArraySupport
          storageBufferOffset += bytesStored
        else
          # Instead of one big array with each storage as a view into it, they're all separate, so let's keep 'em around for flattening.
          storageBufferOffset += storage.length
          o.storageBuffer.push storage

    o.specialKeysToValues = [null, Infinity, NaN]
    # Whatever is in specialKeysToValues index 0 will be default for anything missing, so let's make sure it's null.
    # Don't think we can include undefined or it'll be treated as a sparse array; haven't tested performance.
    o.specialValuesToKeys = {}
    for specialValue, i in o.specialKeysToValues
      o.specialValuesToKeys[specialValue] = i

    t1 = now()
    o.frameHashes = []
    for frameIndex in [startFrame ... endFrame]
      o.frameHashes.push @frames[frameIndex].serialize(frameIndex - startFrame, o.trackedPropertiesThangIDs, o.trackedPropertiesPerThangIndices, o.trackedPropertiesPerThangTypes, trackedPropertiesPerThangValues, o.specialValuesToKeys, o.specialKeysToValues)
    t2 = now()

    unless typedArraySupport
      flattened = []
      for storage in o.storageBuffer
        for value in storage
          flattened.push value
      o.storageBuffer = flattened

    #console.log 'Allocating memory:', (t1 - t0).toFixed(0), 'ms; assigning values:', (t2 - t1).toFixed(0), 'ms, so', ((t2 - t1) / nFrames).toFixed(3), 'ms per frame for', nFrames, 'frames'
    #console.log 'Got', transferableObjects, 'transferable objects and', nontransferableObjects, 'nontransferable; stored', transferableStorageBytesNeeded, 'bytes transferably'

    o.thangs = (t.serialize() for t in @thangs.concat(@extraneousThangs ? []))
    o.scriptNotes = (sn.serialize() for sn in @scriptNotes)
    if o.scriptNotes.length > 200
      console.log 'Whoa, serializing a lot of WorldScriptNotes here:', o.scriptNotes.length
    {serializedWorld: o, transferableObjects: [o.storageBuffer], startFrame: startFrame, endFrame: endFrame}

  @deserialize: (o, classMap, oldSerializedWorldFrames, finishedWorldCallback, startFrame, endFrame, streamingWorld) ->
    # Code hotspot; optimize it
    #console.log 'Deserializing', o, 'length', JSON.stringify(o).length
    #console.log JSON.stringify(o)
    #console.log 'Got special keys and values:', o.specialValuesToKeys, o.specialKeysToValues
    perf = {}
    perf.t0 = now()
    nFrames = endFrame - startFrame
    w = streamingWorld ? new World o.userCodeMap, classMap
    [w.totalFrames, w.maxTotalFrames, w.frameRate, w.dt, w.scriptNotes, w.victory] = [o.totalFrames, o.maxTotalFrames, o.frameRate, o.dt, o.scriptNotes ? [], o.victory]
    w[prop] = val for prop, val of o.trackedProperties

    perf.t1 = now()
    if w.thangs.length
      for thangConfig in o.thangs when not w.thangMap[thangConfig.id]
        w.thangs.push thang = Thang.deserialize(thangConfig, w, classMap)
        w.setThang thang
    else
      w.thangs = (Thang.deserialize(thang, w, classMap) for thang in o.thangs)
      w.setThang thang for thang in w.thangs
    w.scriptNotes = (WorldScriptNote.deserialize(sn, w, classMap) for sn in o.scriptNotes)
    perf.t2 = now()

    o.trackedPropertiesThangs = (w.getThangByID thangID for thangID in o.trackedPropertiesThangIDs)
    o.trackedPropertiesPerThangValues = []
    for trackedPropertyTypes, thangIndex in o.trackedPropertiesPerThangTypes
      o.trackedPropertiesPerThangValues.push (trackedPropertiesValues = [])
      trackedPropertiesValuesOffsets = o.trackedPropertiesPerThangValuesOffsets[thangIndex]
      for type, propIndex in trackedPropertyTypes
        storage = ThangState.createArrayForType(type, nFrames, o.storageBuffer, trackedPropertiesValuesOffsets[propIndex])[0]
        unless typedArraySupport
          # This could be more efficient
          i = trackedPropertiesValuesOffsets[propIndex]
          storage = o.storageBuffer.slice i, i + storage.length
        trackedPropertiesValues.push storage
    perf.t3 = now()

    perf.batches = 0
    perf.framesCPUTime = 0
    w.frames = [] unless streamingWorld
    clearTimeout @deserializationTimeout if @deserializationTimeout
    @deserializationTimeout = _.delay @deserializeSomeFrames, 1, o, w, finishedWorldCallback, perf, startFrame, endFrame

  # Spread deserialization out across multiple calls so the interface stays responsive
  @deserializeSomeFrames: (o, w, finishedWorldCallback, perf, startFrame, endFrame) =>
    ++perf.batches
    startTime = now()
    for frameIndex in [w.frames.length ... endFrame]
      w.frames.push WorldFrame.deserialize(w, frameIndex - startFrame, o.trackedPropertiesThangIDs, o.trackedPropertiesThangs, o.trackedPropertiesPerThangKeys, o.trackedPropertiesPerThangTypes, o.trackedPropertiesPerThangValues, o.specialKeysToValues, o.frameHashes[frameIndex - startFrame], w.dt * frameIndex)
      elapsed = now() - startTime
      if elapsed > DESERIALIZATION_INTERVAL and frameIndex < endFrame - 1
        #console.log "  Deserialization not finished, let's do it again soon. Have:", w.frames.length, ", wanted from", startFrame, "to", endFrame
        perf.framesCPUTime += elapsed
        @deserializationTimeout = _.delay @deserializeSomeFrames, 1, o, w, finishedWorldCallback, perf, startFrame, endFrame
        return
    @deserializationTimeout = null
    perf.framesCPUTime += elapsed
    @finishDeserializing w, finishedWorldCallback, perf, startFrame, endFrame

  @finishDeserializing: (w, finishedWorldCallback, perf, startFrame, endFrame) ->
    perf.t4 = now()
    w.ended = true
    nFrames = endFrame - startFrame
    totalCPUTime = perf.t3 - perf.t0 + perf.framesCPUTime
    #console.log 'Deserialization:', totalCPUTime.toFixed(0) + 'ms (' + (totalCPUTime / nFrames).toFixed(3) + 'ms per frame).', perf.batches, 'batches. Did', startFrame, 'to', endFrame, 'in', (perf.t4 - perf.t0).toFixed(0) + 'ms wall clock time.'
    if false
      console.log '  Deserializing--constructing new World:', (perf.t1 - perf.t0).toFixed(2) + 'ms'
      console.log '  Deserializing--Thangs and ScriptNotes:', (perf.t2 - perf.t1).toFixed(2) + 'ms'
      console.log '  Deserializing--reallocating memory:', (perf.t3 - perf.t2).toFixed(2) + 'ms'
      console.log '  Deserializing--WorldFrames:', (perf.t4 - perf.t3).toFixed(2) + 'ms wall clock time,', (perf.framesCPUTime).toFixed(2) + 'ms CPU time'
    finishedWorldCallback w

  findFirstChangedFrame: (oldWorld) ->
    return 0 unless oldWorld
    for newFrame, i in @frames
      oldFrame = oldWorld.frames[i]
      break unless oldFrame and ((newFrame.hash is oldFrame.hash) or not newFrame.hash? or not oldFrame.hash?)  # undefined gets in there when streaming at the last frame of each batch for some reason
    firstChangedFrame = i
    if @frames.length is @totalFrames
      if @frames[i]
        console.log 'First changed frame is', firstChangedFrame, 'with hash', @frames[i].hash, 'compared to', oldWorld.frames[i]?.hash
      else
        console.log 'No frames were changed out of all', @frames.length
    firstChangedFrame

  pointsForThang: (thangID, frameStart=0, frameEnd=null, camera=null, resolution=4) ->
    # Optimized
    @pointsForThangCache ?= {}
    cacheKey = thangID
    allPoints = @pointsForThangCache[cacheKey]
    unless allPoints
      allPoints = []
      lastFrameIndex = @frames.length - 1
      lastPos = x: null, y: null
      for frameIndex in [lastFrameIndex .. 0] by -1
        frame = @frames[frameIndex]
        if pos = frame.thangStateMap[thangID]?.getStateForProp 'pos'
          pos = camera.worldToSurface {x: pos.x, y: pos.y} if camera  # without z
          if not lastPos.x? or (Math.abs(lastPos.x - pos.x) + Math.abs(lastPos.y - pos.y)) > 1
            lastPos = pos
        allPoints.push lastPos.y, lastPos.x unless lastPos.y is 0 and lastPos.x is 0
      allPoints.reverse()
      @pointsForThangCache[cacheKey] = allPoints

    points = []
    [lastX, lastY] = [null, null]
    for frameIndex in [Math.floor(frameStart / resolution) ... Math.ceil(frameEnd / resolution)]
      x = allPoints[frameIndex * 2 * resolution]
      y = allPoints[frameIndex * 2 * resolution + 1]
      continue if x is lastX and y is lastY
      lastX = x
      lastY = y
      points.push x, y
    points

  actionsForThang: (thangID, keepIdle=false) ->
    # Optimized
    @actionsForThangCache ?= {}
    cacheKey = thangID + '_' + Boolean(keepIdle)
    cached = @actionsForThangCache[cacheKey]
    return cached if cached
    states = (frame.thangStateMap[thangID] for frame in @frames)
    actions = []
    lastAction = ''
    for state, i in states
      action = state?.getStateForProp 'action'
      continue unless action and (action isnt lastAction or state.actionActivated)
      continue unless state.action isnt 'idle' or keepIdle
      actions.push {frame: i, pos: state.pos, name: action}
      lastAction = action
    @actionsForThangCache[cacheKey] = actions
    return actions

  getTeamColors: ->
    teamConfigs = @teamConfigs or {}
    colorConfigs = {}
    colorConfigs[teamName] = config.color for teamName, config of teamConfigs
    colorConfigs

  teamForPlayer: (n) ->
    playableTeams = @playableTeams ? ['humans']
    playableTeams[n % playableTeams.length]
