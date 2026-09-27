# SkiaMicroRacers
A Micro Machines style top-down racing game prototype built entirely with Skia4Delphi.    
     
SkiaMicroRacers v0.2     
    
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/SkiaMicroRacers)    
     
<img width="639" height="507" alt="Unbenannt" src="https://github.com/user-attachments/assets/c074ba91-8f13-4df3-8169-0fb981c3b9af" />
    
Features:    
   
    Game State Machine: Flow from Start Screen -> Countdown -> Racing -> Results.
    Dynamic Surface Detection: Point-to-line distance checks if cars are on asphalt or grass, dynamically changing acceleration and friction.
    AI Opponents: Computer-controlled cars navigate via waypoints with lateral offsets for varied racing lines.
    Collision Physics: Cars push each other apart, transfer momentum, and spin out on impact.
    Dynamic Camera: Rotating follow-camera that smoothly interpolates with the player's heading.
    Multithreaded Game Loop: Background physics and rendering thread for smooth 60 FPS gameplay.
                
Zipped exe and sample project included.    
        
Changelog:    
        
Version 0.2 - "The Great Ping-Pong Port"   
   
     The Ping-Pong Port: Successfully reverse-engineered and ported back the brilliant track generation and AI logic from Guvacode's C/FPC + Raylib port back to Skia4Delphi. What goes around, comes around in 24 hours!   
     Procedural Tracks: Replaced the static oval with a procedural star-shaped track generator (polar coordinates + noise). Tracks are now dynamically validated to ensure no impossible corners.   
     Dynamic Start Line: The start/finish line is now placed dynamically on the flattest section of the generated track.   
     Next-Gen AI Look-Ahead: AI now scans two waypoints ahead and dynamically brakes (CornerMul) before sharp turns to prevent overshooting.   
     Rubber-Banding AI: AI speed scales dynamically based on lap difference. If they fall behind, they get a slight speed boost; if they run away, they ease off. Keeps races neck-and-neck!   
     Smart Waypoint Switching: AI waypoint progression is now calculated via vector projection and speed-dependent radius, preventing AI cars from circling endlessly around a single point.    
     Stuck-Timer (Timeout): Added a 2-second fallback timer that forces the AI to switch waypoints if they get stuck or rammed off-track.
     Level & Progression System: Winning a race now increments the level. AI gets fundamentally faster (LevelMul) while the player gets a slight max-speed bonus to keep up.   
      
GuvaCode C/FPC/raylib ports:    
  FPC/raylib https://github.com/GuvaCode/MicroRacers-FPC-Ray4Laz-port     
  C/raylib https://github.com/GuvaCode/MicroRacers-Top-Down-Racer-Prototype-C-port    
      
     
🎮 Skia4Delphi Games (each one file, no ext engine):    
   2D MegaCatling (Megaman platformer/shooter) https://github.com/LaMitaOne/Skia-MegaCatling     
   2D Lemmings/Worms/Portal/Touch hybrid https://github.com/LaMitaOne/SkiaLemmings       
   2D Side-scrolling space shooter https://github.com/LaMitaOne/SkiaStarPatrols    
   2D Tetris clone https://github.com/LaMitaOne/Skiatris     
   2D Skia Powder (Falling Sand Simulation) https://github.com/LaMitaOne/Skia-Powder    
   2D BombRunner (Bomberman clone) https://github.com/LaMitaOne/SkiaBombRunner     
   2.5D C&C style isometric rts https://github.com/LaMitaOne/Skia-RTS-Game   
   2.5D Isometric cat game https://github.com/LaMitaOne/Skia-A-Cats-Life    
   2.5D Raycasting doom base https://github.com/LaMitaOne/SkiaDoomBase    
   2.5D Voxel Raycasting Comanche https://github.com/LaMitaOne/Skia-Voxel-Comanche      
   3D better go to https://github.com/castle-engine     
     
🎮 Game components FMX:    
   MRX Gamepad Core https://github.com/LaMitaOne/MRX-Gamepad-Core     
        
If you want to tip me a coffee.. :)   
    
<p align="center">
  <a href="https://www.paypal.com/donate/?hosted_button_id=RX5KTTMXW497Q">
    <img src="https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif" alt="Donate with PayPal"/>
  </a>
</p>

   
