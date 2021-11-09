# cool-days-video-extracter

Bash script automating the extraction of the video rushes from the COOL Days 2021.

This script is filling a few functions:
* cut the rushs at the right timecodes corresponding to the start/end time of each talk
* converting all the talks to a more precise timecoding container (MKV)
* cut the first and last 2 seconds of the talk in order to respectively add a fade in and a fade out effect
* convert and add the Blender animated title
* add 7 seconds of purple trailer at the end of each talk to avoid the video from being truncated when being in a playlist and to allow to add the featured previous and next videos using the YouTube Studio features
* avoid a full reencoding of the video by cutting and concatenating at the right locations (only the time periods requiring reencoding are rencoded), allowing the original quality to be preserved.


The one-liner we used to generate the videos:
```
./cool-days-video-extracter.sh -e ../../export/ -t ../../titles-intro-outro/ -r ../../rushes/obs-recordings-videos/
```

The first step of the script which consists in the video extraction from the rushes can be bypassed using the `-s` argument (s for sskip).

```
COOL-Days Video Extracter

A simple command line tool to export the videos of the COOL-Days 2021

cool-days-video-extracter.sh --extracted-folder EXTRACTED-FOLDER [ --skip-1 ] \
        --rushes-folder RUSHES-FOLDER --titles-folder TITLES-FOLDER [ --help ]

 -e | --extracted-folder
                  The folder containing the extracted videos
 -s | --skip-1    Skip the video extraction from the initial rushes
 -r | --rushes-folder
                  The folder containing the video rushes
 -t | --titles-folder
                  The folder containing the video titles
 -h | --help      Show this help message
 ```

## Dependencies

Using:
* [bash-argsparse - An high level argument parsing library for bash](https://github.com/Anvil/bash-argsparse/)
* [wget/shut - a simple shell utility library](https://github.com/wget/shut)

## License

MIT