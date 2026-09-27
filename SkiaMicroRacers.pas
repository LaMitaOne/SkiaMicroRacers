{*******************************************************************************
  SkiaMicroRacers v0.2 (Top-Down Racer Prototype)
********************************************************************************
  A top-down racing game built entirely with Skia4Delphi.
  Architecture & Features:
  - Game State Machine: Controls the flow from Start Screen -> Countdown ->
    Racing -> Results Screen.
  - Surface Detection: Point-to-line-segment distance determines if a car is
    on asphalt or grass, dynamically changing acceleration and friction.
  - Procedural Track Generation: Star-shaped closed curve in polar coordinates,
    regenerated until max turn angles are below safe limits.
  - AI Opponents: Computer-controlled cars navigate the track by steering
    towards target waypoints. They feature look-ahead braking for sharp corners,
    rubber-banding to keep races close, and speed-dependent waypoint switching.
  - Collision Physics: Cars push each other apart upon collision, transferring
    momentum and causing visual spins, allowing for aggressive ramming.
  - Camera System: A dynamic, rotating follow-camera aligns smoothly with the
    player's car heading using linear interpolation.
  - Level Progression: Winning a race increments the level, making AI faster.
  Author:  Lara Miriam Tamy Reschke
  License: MIT
*******************************************************************************}
unit SkiaMicroRacers;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math,
  System.Generics.Collections, System.UITypes, System.SyncObjs, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Skia, System.Skia;

type
  {
    TGameState
    Defines the current phase of the game loop.
    - gsReady: Initial menu screen.
    - gsCountdown: 3, 2, 1, GO! sequence before movement is allowed.
    - gsRacing: Active gameplay phase.
    - gsFinished: Post-race screen displaying rankings.
  }
  TGameState = (gsReady, gsCountdown, gsRacing, gsFinished);
  {
    TTrackPoint
    Represents a single node in the track's center-line path.
    - X, Y: World coordinates of the node.
    - Angle: The heading (in degrees) pointing towards the next node.
  }

  TTrackPoint = record
    X, Y: Single;
    Angle: Single;
  end;
  {
    TCar
    Base class for both Player and AI controlled vehicles.
    Holds physics state, lap tracking, and rendering information.
  }

  TCar = class
  private
    FTargetIndex: Integer; // The waypoint index the AI is currently steering towards.
  public
    X, Y: Single;
    Angle: Single;         // Heading in degrees (0 = Right, 90 = Down)
    Speed: Single;          // Forward velocity (can be negative for reverse)
    LapsCompleted: Integer; // Number of full laps finished (0 at start)
    Name: string;
    Color: Cardinal;
    IsPlayer: Boolean;
    CanCountLap: Boolean;   // Debounce flag to prevent multi-counting per line crossing
    Finished: Boolean;
    FinalRank: Integer;
    Offset: Single;         // AI specific: Lateral offset from track center to create varied lines
    WaypointTimer: Single;  // AI specific: Timer to force-switch waypoints if stuck
    constructor Create(AName: string; AColor: Cardinal; AIsPlayer: Boolean);
    procedure Reset(AX, AY: Single; AAngle: Single);
  end;

  TSkiaMicroRacers = class(TSkCustomControl)
  private
    // Multithreading & Synchronization
    FThread: TThread;
    FActive: Boolean;
    FLock: TCriticalSection;   // Prevents race conditions between input and physics
    FKeys: set of Byte;        // Tracks currently pressed keys
    // Camera State
    FCameraX, FCameraY: Single;
    FCameraAngle: Single;      // Camera rotates to match car heading
    // Track Data
    FTrackPoints: TArray<TTrackPoint>; // Array defining the track's center line
    FTrackWidth: Single;               // Total width of the drivable road
    FStartIndex: Integer;              // The index of the point defining the start/finish line
    // Game Logic
    FGameState: TGameState;
    FCountdownTimer: Single;
    FRaceTimer: Single;
    FTotalLaps: Integer;
    FLevel: Integer;           // Current difficulty level
    FWins: Integer;           // Total races won by the player
    // Cars
    FCars: TObjectList<TCar>;
    FPlayerCar: TCar;
    // Core Methods
    procedure InitRace;
    procedure GenerateTrack;
    function IsOnTrack(X, Y: Single; out DistFromCenter: Single): Boolean;
    procedure DoPhysicsUpdate(DeltaSec: Double);
    procedure UpdateCar(Car: TCar; DeltaSec: Double);
    procedure UpdateAI(Car: TCar; DeltaSec: Double);
    procedure ResolveCollisions;
    procedure CheckLap(Car: TCar);
    procedure StartCountdown;
    procedure CheckRaceFinish;
    procedure SafeInvalidate;
    procedure StartThread;
    procedure StopThread;
    function MeasureTextWidth(const AText: string; const AFont: ISkFont; const APaint: ISkPaint): Single;
    function LevelMul: Single;
  protected
    // Rendering & Input
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

const
  // Difficulty scaling
  LEVEL_STEP = 0.06;
  LEVEL_MAX_MUL = 1.60;
  PLAYER_BONUS = 5.0;

  // Base AI (level 1)
  AI_BASE_SPEED = 270.0;
  AI_BASE_ACCEL = 420.0;

  // AI waypoint following
  AI_WP_MIN_RADIUS = 70.0;
  AI_WP_SPEED_FACTOR = 0.30;
  AI_OFFSET_LIMIT = 15.0;
  AI_WP_TIMEOUT = 2.0;

  // AI look-ahead braking
  AI_CORNER_START = 15.0;
  AI_CORNER_FULL = 90.0;
  AI_CORNER_MIN_MUL = 0.50;

  // Track generator
  NUM_POINTS = 32;
  BASE_RADIUS = 720.0;
  WORLD_CENTER_X = 1500.0;
  WORLD_CENTER_Y = 1500.0;
  MAX_ALLOWED_TURN = 24.0;
  MAX_GEN_ATTEMPTS = 80;

{ TCar }

constructor TCar.Create(AName: string; AColor: Cardinal; AIsPlayer: Boolean);
begin
  inherited Create;
  Name := AName;
  Color := AColor;
  IsPlayer := AIsPlayer;
  LapsCompleted := 0;
  Finished := False;
  FinalRank := 0;
end;

procedure TCar.Reset(AX, AY: Single; AAngle: Single);
begin
  X := AX;
  Y := AY;
  Angle := AAngle;
  Speed := 0;
  LapsCompleted := 0;
  CanCountLap := False;
  Finished := False;
  FinalRank := 0;
  FTargetIndex := 1;
  WaypointTimer := 0;
end;

{ TSkiaMicroRacers }

constructor TSkiaMicroRacers.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  // UI Setup
  Align := TAlignLayout.Client;
  HitTest := True;     // Enable mouse/touch capture
  CanFocus := True;    // Enable keyboard focus
  TabStop := True;
  // Initialize Game State
  FActive := True;
  FTotalLaps := 3;
  FCars := TObjectList<TCar>.Create(True); // True = List owns the objects and frees them
  FLevel := 1;
  FWins := 0;
  InitRace;
  // Start the background physics/render loop
  StartThread;
end;

destructor TSkiaMicroRacers.Destroy;
begin
  StopThread;
  FreeAndNil(FCars);
  FreeAndNil(FLock);
  inherited;
end;

{ Initializes a new race. Resets cars, track, and game state to default. }
procedure TSkiaMicroRacers.InitRace;
var
  I: Integer;
  Car: TCar;
  Colors: array[0..3] of Cardinal;
  StartPtX, StartPtY, StartAng: Single;
  AlongOffset, LateralOffset: Single;
  DirX, DirY, PerpX, PerpY: Single;
begin
  // Define car colors (Red, Blue, Green, Yellow)
  Colors[0] := $FFFF0000;
  Colors[1] := $FF0000FF;
  Colors[2] := $FF00FF00;
  Colors[3] := $FFFFFF00;

  FTrackWidth := 180; // Width of the road in pixels
  GenerateTrack;      // Generate a new random track layout
  FCars.Clear;

  // Determine start position and orientation based on generated track
  StartPtX := FTrackPoints[FStartIndex].X;
  StartPtY := FTrackPoints[FStartIndex].Y;
  StartAng := FTrackPoints[FStartIndex].Angle;

  DirX  := Cos(DegToRad(StartAng));
  DirY  := Sin(DegToRad(StartAng));
  PerpX := -DirY;
  PerpY :=  DirX;

  // Create Player and 3 AI Cars
  for I := 0 to 3 do
  begin
    if I = 0 then
      Car := TCar.Create('Player', Colors[I], True)
    else
      Car := TCar.Create('AI ' + IntToStr(I), Colors[I], False);

    // Arrange cars in a grid format behind the start line
    AlongOffset   := -I * 45;
    LateralOffset := ((I mod 2) * 40) - 20;

    Car.Reset(
      StartPtX + DirX * AlongOffset + PerpX * LateralOffset,
      StartPtY + DirY * AlongOffset + PerpY * LateralOffset,
      StartAng);

    // Give AI a preferred lane offset so they don't drive perfectly on the center line
    Car.Offset := ((I * 40) mod 100) - 50;
    if Car.Offset > AI_OFFSET_LIMIT then Car.Offset := AI_OFFSET_LIMIT;
    if Car.Offset < -AI_OFFSET_LIMIT then Car.Offset := -AI_OFFSET_LIMIT;

    // Set the first waypoint target
    Car.FTargetIndex := (FStartIndex + 1) mod NUM_POINTS;
    Car.WaypointTimer := 0;

    FCars.Add(Car);
  end;

  FPlayerCar := FCars[0];
  // Snap camera to player immediately
  FCameraX := FPlayerCar.X;
  FCameraY := FPlayerCar.Y;
  FCameraAngle := FPlayerCar.Angle;
  FGameState := gsReady;
end;

{
  Procedural track generation using polar coordinates and noise.
  Generates a star-shaped closed curve and ensures curves are not too sharp.
}
procedure TSkiaMicroRacers.GenerateTrack;
var
  I: Integer;
  Theta, R: Single;
  NoiseA1, NoiseA2, NoiseA3: Single;
  NoiseP1, NoiseP2, NoiseP3: Single;
  K1, K2, K3: Integer;
  D: TPointF;
  BestIdx: Integer;
  BestTurn, TurnDiff, AngleA, AngleB: Single;
  Attempt: Integer;
  OK: Boolean;
begin
  SetLength(FTrackPoints, NUM_POINTS);

  K1 := 2;
  K2 := 3;
  K3 := 5;

  Attempt := 0;
  OK := False;

  // Regenerate track until the max turn angle is within safe limits
  while (not OK) and (Attempt < MAX_GEN_ATTEMPTS) do
  begin
    Inc(Attempt);
    OK := True;

    // Randomize noise amplitudes and phases
    NoiseA1 := 0.07 + Random * 0.05;
    NoiseA2 := 0.04 + Random * 0.03;
    NoiseA3 := 0.02 + Random * 0.02;

    NoiseP1 := Random * 2 * Pi;
    NoiseP2 := Random * 2 * Pi;
    NoiseP3 := Random * 2 * Pi;

    for I := 0 to NUM_POINTS - 1 do
    begin
      Theta := 2 * Pi * I / NUM_POINTS;
      R := BASE_RADIUS * (1
        + NoiseA1 * Cos(K1 * Theta + NoiseP1)
        + NoiseA2 * Cos(K2 * Theta + NoiseP2)
        + NoiseA3 * Cos(K3 * Theta + NoiseP3));

      FTrackPoints[I].X := WORLD_CENTER_X + Cos(Theta) * R;
      FTrackPoints[I].Y := WORLD_CENTER_Y + Sin(Theta) * R;
    end;

    // Calculate angles for each point aiming at the next
    for I := 0 to NUM_POINTS - 1 do
    begin
      D := PointF(FTrackPoints[(I+1) mod NUM_POINTS].X - FTrackPoints[I].X,
                  FTrackPoints[(I+1) mod NUM_POINTS].Y - FTrackPoints[I].Y);
      FTrackPoints[I].Angle := RadToDeg(ArcTan2(D.Y, D.X));
    end;

    // Check for overly sharp turns
    for I := 0 to NUM_POINTS - 1 do
    begin
      AngleA := FTrackPoints[I].Angle;
      AngleB := FTrackPoints[(I+1) mod NUM_POINTS].Angle;
      TurnDiff := Abs(AngleB - AngleA);
      if TurnDiff > 180 then TurnDiff := 360 - TurnDiff;

      if TurnDiff > MAX_ALLOWED_TURN then
      begin
        OK := False;
        Break;
      end;
    end;
  end;

  // Find the flattest section to place the start/finish line
  BestIdx := 0;
  BestTurn := 99999;
  for I := 0 to NUM_POINTS - 1 do
  begin
    AngleA := FTrackPoints[I].Angle;
    AngleB := FTrackPoints[(I+1) mod NUM_POINTS].Angle;
    TurnDiff := Abs(AngleB - AngleA);
    if TurnDiff > 180 then TurnDiff := 360 - TurnDiff;
    if TurnDiff < BestTurn then
    begin
      BestTurn := TurnDiff;
      BestIdx := I;
    end;
  end;
  FStartIndex := BestIdx;
end;

{
  Checks if a given coordinate (X, Y) is on the drivable road.
  Finds the shortest distance from the point to any of the track's center line
  segments. If the distance is less than half the track width, it's on track.
}
function TSkiaMicroRacers.IsOnTrack(X, Y: Single; out DistFromCenter: Single): Boolean;
var
  I: Integer;
  P1, P2, Pt: TPointF;
  LineVec, PointVec: TPointF;
  LineLen, ProjT, ProjX, ProjY: Single;
  MinDist: Single;
begin
  Result := False;
  MinDist := 99999;
  Pt := PointF(X, Y);
  // Iterate through all line segments (Point I to Point I+1) including the wrap-around
  for I := 0 to High(FTrackPoints) do
  begin
    P1 := PointF(FTrackPoints[I].X, FTrackPoints[I].Y);
    P2 := PointF(FTrackPoints[(I + 1) mod Length(FTrackPoints)].X, FTrackPoints[(I + 1) mod Length(FTrackPoints)].Y);
    LineVec := P2 - P1;
    PointVec := Pt - P1;
    LineLen := LineVec.Length;
    if LineLen > 0 then
    begin
      // Vector Projection: 'ProjT' is a normalized value (0.0 to 1.0)
      ProjT := (PointVec.X * LineVec.X + PointVec.Y * LineVec.Y) / (LineLen * LineLen);
      ProjT := EnsureRange(ProjT, 0, 1);
      // Calculate the exact point on the line closest to our car
      ProjX := P1.X + ProjT * LineVec.X;
      ProjY := P1.Y + ProjT * LineVec.Y;
      // Distance from car to the closest point on the line
      DistFromCenter := Sqrt(Sqr(Pt.X - ProjX) + Sqr(Pt.Y - ProjY));
      if DistFromCenter < MinDist then
        MinDist := DistFromCenter;
    end;
  end;
  DistFromCenter := MinDist;
  Result := (MinDist <= FTrackWidth / 2);
end;

{ Calculates the AI difficulty multiplier based on current level }
function TSkiaMicroRacers.LevelMul: Single;
begin
  Result := 1.0 + (FLevel - 1) * LEVEL_STEP;
  if Result > LEVEL_MAX_MUL then
    Result := LEVEL_MAX_MUL;
end;

{
  Main physics logic. Runs on a background thread.
  Updates timers and car positions based on elapsed time (DeltaSec).
}
procedure TSkiaMicroRacers.DoPhysicsUpdate(DeltaSec: Double);
var
  I: Integer;
  Car: TCar;
begin
  if not FActive then
    Exit;
  // Handle Countdown Timer
  if FGameState = gsCountdown then
  begin
    FCountdownTimer := FCountdownTimer - DeltaSec;
    if FCountdownTimer <= 0 then
      FGameState := gsRacing;
  end;
  if FGameState = gsRacing then
    FRaceTimer := FRaceTimer + DeltaSec;
  // Only update physics if racing or countdown (so cars don't fly off on ready)
  if (FGameState = gsRacing) or (FGameState = gsCountdown) then
  begin
    for I := 0 to FCars.Count - 1 do
    begin
      Car := FCars[I];
      if not Car.Finished then
      begin
        if Car.IsPlayer then
          UpdateCar(Car, DeltaSec)
        else
          UpdateAI(Car, DeltaSec);
      end;
    end;
    // Resolve crashes between cars
    ResolveCollisions;
  end;
  // Smooth Camera follow for player
  FCameraX := FCameraX + (FPlayerCar.X - FCameraX) * 5 * DeltaSec;
  FCameraY := FCameraY + (FPlayerCar.Y - FCameraY) * 5 * DeltaSec;
  FCameraAngle := FCameraAngle + (FPlayerCar.Angle - FCameraAngle) * 2 * DeltaSec;
end;

{
  Updates player car physics based on keyboard input.
  Max speed scales slightly with level to keep it competitive.
}
procedure TSkiaMicroRacers.UpdateCar(Car: TCar; DeltaSec: Double);
var
  Left, Right, Up, Down: Boolean;
  Accel, Friction, TurnSpeed: Single;
  Rad, VX, VY: Single;
  OnTrack: Boolean;
  DistFromCenter: Single;
  MaxSpeed: Single;
begin
  // Thread-safe reading of keyboard input
  FLock.Acquire;
  try
    Left := (Byte(vkLeft) in FKeys);
    Right := (Byte(vkRight) in FKeys);
    Up := (Byte(vkUp) in FKeys);
    Down := (Byte(vkDown) in FKeys);
  finally
    FLock.Release;
  end;
  // Lock movement during countdown
  if FGameState = gsCountdown then
  begin
    Up := False;
    Down := False;
    Left := False;
    Right := False;
  end;
  // Check surface under car
  OnTrack := IsOnTrack(Car.X, Car.Y, DistFromCenter);
  // Define Physics Parameters based on surface
  Accel := 350;
  if not OnTrack then
    Accel := 100; // Slower acceleration on grass
  Friction := 2.0;
  if not OnTrack then
    Friction := 5.0; // High friction on grass

  // Player gets slightly faster with each level
  MaxSpeed := 300 + (FLevel - 1) * PLAYER_BONUS;

  // Update Speed
  if Up then
    Car.Speed := Min(Car.Speed + Accel * DeltaSec, MaxSpeed)
  else if Down then
    Car.Speed := Max(Car.Speed - Accel * DeltaSec, -150) // Reverse accel with cap
  else
    Car.Speed := Car.Speed - (Car.Speed * Friction * DeltaSec); // Natural slow down

  // Steering (Speed-dependent). Cars shouldn't turn when stationary.
  if Abs(Car.Speed) > 5 then
  begin
    TurnSpeed := 120 * (Car.Speed / MaxSpeed);
    if Left then
      Car.Angle := Car.Angle - TurnSpeed * DeltaSec;
    if Right then
      Car.Angle := Car.Angle + TurnSpeed * DeltaSec;
  end;
  // Update Position using basic trigonometry
  Rad := DegToRad(Car.Angle);
  VX := Cos(Rad) * Car.Speed * DeltaSec;
  VY := Sin(Rad) * Car.Speed * DeltaSec;
  Car.X := Car.X + VX;
  Car.Y := Car.Y + VY;
  CheckLap(Car);
end;

{
  Updates AI car physics.
  Features: Look-ahead braking for corners, speed-dependent waypoint switching,
  timeout fallback, and rubber-banding to keep races close.
}
procedure TSkiaMicroRacers.UpdateAI(Car: TCar; DeltaSec: Double);
var
  TargetPt, NextPt, FarPt: TTrackPoint;
  DesiredAngle, AngleDiff: Single;
  TurnSpeed, Accel: Single;
  Rad, VX, VY: Single;
  DistToTarget, PlainDist: Single;
  PerpX, PerpY, OffsetX, OffsetY: Single;
  UseOffset, AngleDelta: Single;
  OnTrack: Boolean;
  DistFromCenter: Single;
  LapDiff: Integer;
  RubberMul, LevelFactor, MaxAI: Single;
  Seg, CarToTargetVec: TPointF;
  Dot: Single;
  SwitchRadius: Single;
  LookDelta, FarDelta: Single;
  CornerMul: Single;
  Switched: Boolean;
begin
  if FGameState <> gsRacing then
    Exit;

  TargetPt := FTrackPoints[Car.FTargetIndex];
  NextPt   := FTrackPoints[(Car.FTargetIndex + 1) mod Length(FTrackPoints)];
  FarPt    := FTrackPoints[(Car.FTargetIndex + 2) mod Length(FTrackPoints)];

  // Disable offset in sharp corners so AI takes a tighter line
  AngleDelta := Abs(TargetPt.Angle - NextPt.Angle);
  if AngleDelta > 180 then AngleDelta := 360 - AngleDelta;
  if AngleDelta > 12 then
    UseOffset := 0
  else
    UseOffset := Car.Offset;

  // Calculate Offset vector (perpendicular to track)
  PerpX := -Sin(DegToRad(TargetPt.Angle));
  PerpY := Cos(DegToRad(TargetPt.Angle));
  OffsetX := PerpX * UseOffset;
  OffsetY := PerpY * UseOffset;

  DistToTarget := Sqrt(Sqr(Car.X - (TargetPt.X + OffsetX)) + Sqr(Car.Y - (TargetPt.Y + OffsetY)));
  PlainDist := Sqrt(Sqr(Car.X - TargetPt.X) + Sqr(Car.Y - TargetPt.Y));

  // Vector projection to see if car has passed the waypoint
  Seg := PointF(NextPt.X - TargetPt.X, NextPt.Y - TargetPt.Y);
  CarToTargetVec := PointF(Car.X - TargetPt.X, Car.Y - TargetPt.Y);
  Dot := (CarToTargetVec.X * Seg.X) + (CarToTargetVec.Y * Seg.Y);

  // Dynamic switch radius based on speed to prevent overshoot
  SwitchRadius := AI_WP_MIN_RADIUS + Abs(Car.Speed) * AI_WP_SPEED_FACTOR;

  Car.WaypointTimer := Car.WaypointTimer + DeltaSec;
  Switched := False;

  // Switch to next target if close, projected past it, or timeout reached
  if (PlainDist < 10) or (PlainDist < SwitchRadius) or (Dot > 0) then
    Switched := True;
  if Car.WaypointTimer > AI_WP_TIMEOUT then
    Switched := True;

  if Switched then
  begin
    Car.FTargetIndex := (Car.FTargetIndex + 1) mod Length(FTrackPoints);
    Car.WaypointTimer := 0;

    TargetPt := FTrackPoints[Car.FTargetIndex];
    NextPt   := FTrackPoints[(Car.FTargetIndex + 1) mod Length(FTrackPoints)];
    FarPt    := FTrackPoints[(Car.FTargetIndex + 2) mod Length(FTrackPoints)];

    AngleDelta := Abs(TargetPt.Angle - NextPt.Angle);
    if AngleDelta > 180 then AngleDelta := 360 - AngleDelta;
    if AngleDelta > 12 then
      UseOffset := 0
    else
      UseOffset := Car.Offset;

    OffsetX := -Sin(DegToRad(TargetPt.Angle)) * UseOffset;
    OffsetY := Cos(DegToRad(TargetPt.Angle)) * UseOffset;
    DistToTarget := Sqrt(Sqr(Car.X - (TargetPt.X + OffsetX)) + Sqr(Car.Y - (TargetPt.Y + OffsetY)));
  end;

  // Steer towards target
  DesiredAngle := RadToDeg(ArcTan2((TargetPt.Y + OffsetY) - Car.Y, (TargetPt.X + OffsetX) - Car.X));
  AngleDiff := DesiredAngle - Car.Angle;
  // Normalize angle difference
  if AngleDiff > 180 then
    AngleDiff := AngleDiff - 360;
  if AngleDiff < -180 then
    AngleDiff := AngleDiff + 360;

  OnTrack := IsOnTrack(Car.X, Car.Y, DistFromCenter);

  // Rubber-banding: Speed up AI if behind player, slow down if ahead
  LapDiff := FPlayerCar.LapsCompleted - Car.LapsCompleted;
  RubberMul := 1.0;
  if LapDiff >= 2 then
    RubberMul := 1.12
  else if LapDiff <= -2 then
    RubberMul := 0.92;

  LevelFactor := LevelMul;

  // Look-ahead braking: check angle difference of upcoming segments
  LookDelta := Abs(TargetPt.Angle - NextPt.Angle);
  if LookDelta > 180 then LookDelta := 360 - LookDelta;
  FarDelta := Abs(NextPt.Angle - FarPt.Angle);
  if FarDelta > 180 then FarDelta := 360 - FarDelta;
  if FarDelta > LookDelta then LookDelta := FarDelta;

  CornerMul := 1.0;
  if LookDelta > AI_CORNER_START then
  begin
    CornerMul := 1.0 - (LookDelta - AI_CORNER_START) / (AI_CORNER_FULL - AI_CORNER_START);
    if CornerMul < AI_CORNER_MIN_MUL then
      CornerMul := AI_CORNER_MIN_MUL;
  end;

  // Calculate final acceleration and max speed
  Accel := AI_BASE_ACCEL * RubberMul * LevelFactor;
  if not OnTrack then Accel := Accel * 0.4;
  if Abs(AngleDiff) > 60 then Accel := Accel * 0.6; // Slow down on sharp turns
  Accel := Accel * CornerMul;

  MaxAI := AI_BASE_SPEED * RubberMul * LevelFactor * CornerMul;
  Car.Speed := Min(Car.Speed + Accel * DeltaSec, MaxAI);

  // Turn towards desired angle
  if Abs(Car.Speed) > 5 then
  begin
    TurnSpeed := 150 * (Car.Speed / 320) * (0.7 + 0.3 * LevelFactor);
    if AngleDiff < 0 then
      Car.Angle := Car.Angle - Min(Abs(AngleDiff), TurnSpeed * DeltaSec)
    else
      Car.Angle := Car.Angle + Min(AngleDiff, TurnSpeed * DeltaSec);
  end;

  // Move
  Rad := DegToRad(Car.Angle);
  VX := Cos(Rad) * Car.Speed * DeltaSec;
  VY := Sin(Rad) * Car.Speed * DeltaSec;
  Car.X := Car.X + VX;
  Car.Y := Car.Y + VY;
  CheckLap(Car);
end;

{
  Resolves collisions between cars.
  Checks overlapping cars and pushes them apart, transferring momentum
  and adding a slight spin for visual effect.
}
procedure TSkiaMicroRacers.ResolveCollisions;
var
  I, J: Integer;
  CarA, CarB: TCar;
  DX, DY, Dist: Single;
  Overlap: Single;
  PushX, PushY: Single;
  SpeedDiff: Single;
begin
  for I := 0 to FCars.Count - 1 do
  begin
    for J := I + 1 to FCars.Count - 1 do
    begin
      CarA := FCars[I];
      CarB := FCars[J];
      DX := CarB.X - CarA.X;
      DY := CarB.Y - CarA.Y;
      Dist := Sqrt(Sqr(DX) + Sqr(DY));
      if Dist < 25.0 then // Cars are roughly 30x20 in size
      begin
        if Dist = 0 then
        begin
          Dist := 0.1;
          DX := 1;
          DY := 0;
        end;
        Overlap := 25.0 - Dist;
        PushX := (DX / Dist) * (Overlap / 2);
        PushY := (DY / Dist) * (Overlap / 2);
        // Push apart
        CarA.X := CarA.X - PushX;
        CarA.Y := CarA.Y - PushY;
        CarB.X := CarB.X + PushX;
        CarB.Y := CarB.Y + PushY;
        // Momentum transfer
        SpeedDiff := (CarA.Speed - CarB.Speed) * 0.5;
        CarA.Speed := CarA.Speed - SpeedDiff * 0.5;
        CarB.Speed := CarB.Speed + SpeedDiff * 0.5;
        // Add lateral kick to make crashes spin out
        CarA.Angle := CarA.Angle - (DX / Dist) * 5;
        CarB.Angle := CarB.Angle + (DX / Dist) * 5;
      end;
    end;
  end;
end;

{
  Checks if a car has crossed the finish line in the correct direction.
  Uses the dynamically generated start index.
  Updates lap count and race state accordingly.
}
procedure TSkiaMicroRacers.CheckLap(Car: TCar);
var
  DistToStart: Single;
  AngleDiff: Single;
  StartPt: TTrackPoint;
  I: Integer;
begin
  StartPt := FTrackPoints[FStartIndex];
  DistToStart := Sqrt(Sqr(Car.X - StartPt.X) + Sqr(Car.Y - StartPt.Y));

  // Check if car is close to the start/finish line
  if DistToStart < 90 then
  begin
    if not Car.CanCountLap then
    begin
      // Ensure the car is moving in the correct direction
      AngleDiff := Abs(Car.Angle - StartPt.Angle);
      if AngleDiff > 180 then
        AngleDiff := 360 - AngleDiff;
      if AngleDiff < 60 then
      begin
        // First crossing (Lap 1) does not increment LapsCompleted,
        // it only initializes the counter.
        if Car.LapsCompleted = 0 then
          Car.LapsCompleted := 1 // You are now in Lap 1, 0 are done.
        else
          // Subsequent crossings mean the previous lap is fully completed.
          Car.LapsCompleted := Car.LapsCompleted + 1;
        Car.CanCountLap := True;

        // Check if race is finished for this car
        if (Car.LapsCompleted > FTotalLaps) and not Car.Finished then
        begin
          Car.Finished := True;
          Car.FinalRank := 1;
          for I := 0 to FCars.Count - 1 do
            if (FCars[I] <> Car) and FCars[I].Finished then
              Inc(Car.FinalRank);
          CheckRaceFinish;
        end;
      end;
    end;
  end
  else
  begin
    // Reset debounce flag only when significantly far away
    // to prevent oscillation while driving directly over the line.
    if DistToStart > 120 then
      Car.CanCountLap := False;
  end;
end;

{ Ends the race if all cars have finished or player has finished. Increments Level/Wins. }
procedure TSkiaMicroRacers.CheckRaceFinish;
var
  FinishedCount: Integer;
  I: Integer;
begin
  FinishedCount := 0;
  for I := 0 to FCars.Count - 1 do
    if FCars[I].Finished then
      Inc(FinishedCount);

  if FinishedCount >= FCars.Count then
  begin
    if FPlayerCar.FinalRank = 1 then
      Inc(FWins);
    FGameState := gsFinished;
  end;
end;

{ Triggers the start sequence. }
procedure TSkiaMicroRacers.StartCountdown;
begin
  FGameState := gsCountdown;
  FCountdownTimer := 4.0; // 3, 2, 1, GO!
  FRaceTimer := 0;
end;

{ Safely triggers a redraw from a background thread using TThread.Queue }
procedure TSkiaMicroRacers.SafeInvalidate;
begin
  if csDestroying in ComponentState then
    Exit;
  TThread.Queue(nil,
    procedure
    begin
      if not (csDestroying in ComponentState) and Assigned(Self) then
      begin
        Redraw;
        Repaint;
      end;
    end);
end;

{ Initializes the background game loop thread }
procedure TSkiaMicroRacers.StartThread;
begin
  if Assigned(FThread) then
    Exit;
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, NowTime, DeltaMS: Cardinal;
    begin
      LastTime := TThread.GetTickCount;
      while not TThread.CheckTerminated do
      begin
        NowTime := TThread.GetTickCount;
        DeltaMS := NowTime - LastTime;
        if DeltaMS = 0 then
          DeltaMS := 1; // Prevent division by zero
        LastTime := NowTime;
        if FActive then
        begin
          DoPhysicsUpdate(DeltaMS / 1000); // Convert milliseconds to seconds
          SafeInvalidate;                  // Request a redraw
        end;
        Sleep(16); // Target ~60 FPS (1000ms / 60 = ~16.6ms)
      end;
    end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

{ Stops the background thread gracefully }
procedure TSkiaMicroRacers.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50); // Give the thread a moment to exit its loop
  end;
end;

{
  Helper to measure text width for UI centering.
  Uses Skia's internal font metrics, with a fallback estimation.
}
function TSkiaMicroRacers.MeasureTextWidth(const AText: string; const AFont: ISkFont; const APaint: ISkPaint): Single;
begin
  if not Assigned(AFont) or not Assigned(APaint) then
    Exit(AText.Length * 10.0);
  try
    Result := AFont.MeasureText(AText, APaint);
  except
    Result := AText.Length * (AFont.Size * 0.5);
  end;
end;

{ DRAWING }
{
  Main rendering method. Draws the world relative to the camera, then UI.
}
procedure TSkiaMicroRacers.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  Paint: ISkPaint;
  ScreenCX, ScreenCY: Single;
  I: Integer;
  PerpX, PerpY: Single;
  PathBuilder: ISkPathBuilder;
  TrackPath: ISkPath;
  Font: ISkFont;
  DashPathEffect: ISkPathEffect;
  Car: TCar;
  CountdownText: string;
  TextWidth: Single;
  DisplayLap, DisplayDone: Integer;
begin
  // 1. Clear screen with grass background
  ACanvas.Clear($FF1a3a1a);
  ScreenCX := Width / 2;
  ScreenCY := Height / 2;

  // 2. Apply Camera Transformations
  ACanvas.Save;
  ACanvas.Translate(ScreenCX, ScreenCY); // Move world to center of screen
  ACanvas.Rotate(-FCameraAngle);         // Rotate world opposite to camera
  ACanvas.Translate(-FCameraX, -FCameraY); // Pan world based on camera position

  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;

  // 3. Draw Grass Area (World Bounds covering the generated track)
  Paint.Color := $FF2E8B57;
  ACanvas.DrawRect(TRectF.Create(0, 0, 3000, 3000), Paint);

  // 4. Build Track Path
  PathBuilder := TSkPathBuilder.Create;
  PathBuilder.MoveTo(FTrackPoints[0].X, FTrackPoints[0].Y);
  for I := 1 to High(FTrackPoints) do
    PathBuilder.LineTo(FTrackPoints[I].X, FTrackPoints[I].Y);
  PathBuilder.Close; // Close the loop
  TrackPath := PathBuilder.Detach;

  // 5. Draw Track Asphalt
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.Color := $FF333333;
  Paint.StrokeWidth := FTrackWidth;
  Paint.StrokeCap := TSkStrokeCap.Round;
  Paint.StrokeJoin := TSkStrokeJoin.Round;
  ACanvas.DrawPath(TrackPath, Paint);

  // 6. Draw Center Dashed Line
  Paint.Color := $FFFFFF00;
  Paint.StrokeWidth := 4;
  DashPathEffect := TSkPathEffect.MakeDash([30.0, 30.0], 0);
  Paint.PathEffect := DashPathEffect;
  ACanvas.DrawPath(TrackPath, Paint);
  Paint.PathEffect := nil; // Reset effect

  // 7. Draw Start/Finish Line (Checkered pattern) at StartIndex
  Paint.Style := TSkPaintStyle.Fill;
  PerpX := -Sin(DegToRad(FTrackPoints[FStartIndex].Angle));
  PerpY := Cos(DegToRad(FTrackPoints[FStartIndex].Angle));
  for I := -4 to 4 do
  begin
    if I mod 2 = 0 then
      Paint.Color := $FFFFFFFF
    else
      Paint.Color := $FF000000;
    ACanvas.DrawRect(TRectF.Create(
      FTrackPoints[FStartIndex].X + (PerpX * I * 20) - 10,
      FTrackPoints[FStartIndex].Y + (PerpY * I * 20) - 10,
      FTrackPoints[FStartIndex].X + (PerpX * I * 20) + 10,
      FTrackPoints[FStartIndex].Y + (PerpY * I * 20) + 10), Paint);
  end;

  // 8. Draw Cars
  for Car in FCars do
  begin
    ACanvas.Save;
    ACanvas.Translate(Car.X, Car.Y);
    ACanvas.Rotate(Car.Angle);
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := Car.Color; // Body
    ACanvas.DrawRoundRect(TRectF.Create(-15, -10, 15, 10), 3, 3, Paint);
    Paint.Color := $FF202020; // Windshield
    ACanvas.DrawRoundRect(TRectF.Create(0, -8, 10, 8), 2, 2, Paint);
    Paint.Color := $FFFFFFFF; // Headlights
    ACanvas.DrawCircle(PointF(12, -6), 2, Paint);
    ACanvas.DrawCircle(PointF(12, 6), 2, Paint);
    ACanvas.Restore;
  end;

  ACanvas.Restore; // Restore canvas to screen state (for UI)

  // 9. Draw UI (Screen Space)
  Font := TSkFont.Create;
  Paint := TSkPaint.Create;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.AntiAlias := True;

  case FGameState of
    gsReady:
      begin
        // Dim background
        Paint.Color := $88000000;
        ACanvas.DrawRect(ADest, Paint);
        Paint.Color := TAlphaColors.White;
        Font.Size := 48;
        TextWidth := MeasureTextWidth('MICRO RACERS', Font, Paint);
        ACanvas.DrawSimpleText('MICRO RACERS', (Width - TextWidth) / 2, Height / 2 - 50, Font, Paint);

        Font.Size := 24;
        TextWidth := MeasureTextWidth('Level ' + IntToStr(FLevel) + '   Wins ' + IntToStr(FWins), Font, Paint);
        ACanvas.DrawSimpleText('Level ' + IntToStr(FLevel) + '   Wins ' + IntToStr(FWins), (Width - TextWidth) / 2, Height / 2, Font, Paint);

        Font.Size := 24;
        TextWidth := MeasureTextWidth('Press ENTER to Start', Font, Paint);
        ACanvas.DrawSimpleText('Press ENTER to Start', (Width - TextWidth) / 2, Height / 2 + 40, Font, Paint);
      end;
    gsCountdown:
      begin
        if FCountdownTimer > 1 then
          CountdownText := IntToStr(Trunc(FCountdownTimer))
        else if FCountdownTimer > 0 then
          CountdownText := 'GO!'
        else
          CountdownText := '';
        if CountdownText <> '' then
        begin
          Paint.Color := TAlphaColors.White;
          Font.Size := 96;
          TextWidth := MeasureTextWidth(CountdownText, Font, Paint);
          ACanvas.DrawSimpleText(CountdownText, (Width - TextWidth) / 2, Height / 2 + 30, Font, Paint);
        end;
      end;
    gsRacing:
      begin
        Paint.Color := TAlphaColors.White;
        Font.Size := 20;
        // UI Display Logic
        DisplayLap := FPlayerCar.LapsCompleted;
        if DisplayLap = 0 then
          DisplayLap := 1;
        if DisplayLap > FTotalLaps then
          DisplayLap := FTotalLaps;
        DisplayDone := FPlayerCar.LapsCompleted;
        if DisplayDone > 0 then
          DisplayDone := DisplayDone - 1;

        ACanvas.DrawSimpleText('Lap: ' + IntToStr(DisplayLap) + '/' + IntToStr(FTotalLaps), 10, 30, Font, Paint);
        ACanvas.DrawSimpleText('Done: ' + IntToStr(DisplayDone) + '/' + IntToStr(FTotalLaps), 10, 60, Font, Paint);
        ACanvas.DrawSimpleText('Time: ' + FloatToStrF(FRaceTimer, ffFixed, 5, 2), 10, 90, Font, Paint);

        // Draw rankings on right side
        for I := 0 to FCars.Count - 1 do
        begin
          Car := FCars[I];
          DisplayDone := Car.LapsCompleted;
          if DisplayDone > 0 then
            DisplayDone := DisplayDone - 1;
          ACanvas.DrawSimpleText(Car.Name + ' - done: ' + IntToStr(DisplayDone), Width - 150, 30 + (I * 25), Font, Paint);
        end;
      end;
    gsFinished:
      begin
        Paint.Color := $88000000;
        ACanvas.DrawRect(ADest, Paint);

        if FPlayerCar.FinalRank = 1 then
        begin
          Paint.Color := TAlphaColors.Yellow;
          Font.Size := 48;
          TextWidth := MeasureTextWidth('YOU WIN!', Font, Paint);
          ACanvas.DrawSimpleText('YOU WIN!', (Width - TextWidth) / 2, 80, Font, Paint);
        end
        else
        begin
          Paint.Color := TAlphaColors.Red;
          Font.Size := 48;
          TextWidth := MeasureTextWidth('YOU LOST', Font, Paint);
          ACanvas.DrawSimpleText('YOU LOST', (Width - TextWidth) / 2, 80, Font, Paint);
        end;

        Paint.Color := TAlphaColors.White;
        Font.Size := 24;
        for I := 0 to FCars.Count - 1 do
        begin
          Car := FCars[I];
          if FPlayerCar = Car then
            Paint.Color := TAlphaColors.Yellow
          else
            Paint.Color := TAlphaColors.White;
          ACanvas.DrawSimpleText(IntToStr(I + 1) + '. ' + Car.Name + ' (Laps: ' + IntToStr(Car.LapsCompleted - 1) + ')', (Width / 2) - 100, 150 + (I * 35), Font, Paint);
        end;

        Paint.Color := TAlphaColors.White;
        Font.Size := 18;
        TextWidth := MeasureTextWidth('Press R to Restart', Font, Paint);
        ACanvas.DrawSimpleText('Press R to Restart', (Width - TextWidth) / 2, Height - 50, Font, Paint);
      end;
  end;
end;

{ Input Handlers: Capture keys and store them in a set. Thread-safe. }
procedure TSkiaMicroRacers.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  C: WideChar;
begin
  FLock.Acquire;
  try
    // Check Arrow Keys via Key
    case Key of
      vkLeft:
        Include(FKeys, vkLeft);
      vkRight:
        Include(FKeys, vkRight);
      vkUp:
        Include(FKeys, vkUp);
      vkDown:
        Include(FKeys, vkDown);
    end;
    // Check WASD via KeyChar (works regardless of Shift/Capslock)
    C := UpCase(KeyChar);
    case C of
      'A':
        Include(FKeys, vkLeft);
      'D':
        Include(FKeys, vkRight);
      'W':
        Include(FKeys, vkUp);
      'S':
        Include(FKeys, vkDown);
    end;
  finally
    FLock.Release;
  end;

  // Game State Triggers
  if FGameState = gsReady then
  begin
    if (Key = vkReturn) then
      StartCountdown;
  end
  else if FGameState = gsFinished then
  begin
    if (C = 'R') then
    begin
      // Increase level if player won
      if FPlayerCar.FinalRank = 1 then
        Inc(FLevel);
      InitRace;
      StartCountdown;
    end;
  end;
  Key := 0;
  KeyChar := #0;
  inherited;
end;

procedure TSkiaMicroRacers.KeyUp(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  C: WideChar;
begin
  FLock.Acquire;
  try
    case Key of
      vkLeft:
        Exclude(FKeys, vkLeft);
      vkRight:
        Exclude(FKeys, vkRight);
      vkUp:
        Exclude(FKeys, vkUp);
      vkDown:
        Exclude(FKeys, vkDown);
    end;
    C := UpCase(KeyChar);
    case C of
      'A':
        Exclude(FKeys, vkLeft);
      'D':
        Exclude(FKeys, vkRight);
      'W':
        Exclude(FKeys, vkUp);
      'S':
        Exclude(FKeys, vkDown);
    end;
  finally
    FLock.Release;
  end;
  Key := 0;
  KeyChar := #0;
  inherited;
end;

end.
