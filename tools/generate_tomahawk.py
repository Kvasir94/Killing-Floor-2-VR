"""Export the current RAVEN-7 through Blender; preserves existing scenes.

Run with Blender --background --python tools/generate_tomahawk.py, or invoke
raven7_model.main() through Blender MCP. The builder hashes both source files.
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from raven7_model import main

if __name__ == '__main__':
    main()
