#!/usr/bin/env bash

# shellcheck disable=SC1091
. "${0%/*}/utils.sh"
. "${0%/*}/argsparse.sh"

set_colors
set_effects

require_deps 'date' 'ffmpeg' 'ffprobe' || exit 1

function timediff() {
    unset retval
    secdiff=$((
        $(date -u -d "$2" +%s) - $(date -u -d "$1" +%s)
    ))
    nanosecdiff=$((
        $(date -u -d "$2" +%N) - $(date -u -d "$1" +%N)
    ))
    retval="$(date -u -d @"$secdiff.$nanosecdiff" "+%T.%N")"
}

# When passed to a local variable, multiple spaces are replaced by only
# one meaning the string is not equal to zero any more.
# Stricter comparison required, hence this function.
function is_duration_valid() {
    unset retval
    local duration="$1"

    explode ":" "$duration"
    for i in "${retval[@]}"; do
        if ! isNumber "$i"; then
            return 1
        fi
    done

    return 0
}

function extract_from_rush() {
    local rushFile="$1"
    local startTime="$2"
    local durationTime="$3"
    local destFile="$4"

    # ffmpeg:
    # -ss means beginning time.
    # -t is the length of final part.
    # -i is the input file, in the above case it's a file called 'input.mkv'.
    # -vcodec stands for the video codec to encode the output file. 'copy' means you're using the same codec as the input file.
    # -acodec is the audio codec.
    # output.mkv is the output file, you can rename it as you need.
    if ! is_duration_valid "$durationTime"; then
        ffmpeg -y -ss "$startTime" -i "$rushFile" -c copy "$destFile"
    else
        ffmpeg -y -ss "$startTime" -t "$durationTime" -i "$rushFile" -c copy "$destFile"
    fi
}

function get_video_duration() {
    unset retval
    retval="$(ffprobe -v error -sexagesimal -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1")"
}

function create_final_video() {
    local srcFile="$1"
    local titleFilesLocation="$2"
    # Remove extension
    local destFile="${srcFile%.*}"
    local destFileWOPath="${destFile##*/}"
    local destFolder="${srcFile%/*}"
    get_video_duration "${srcFile}"
    timediff 00:00:03 "${retval}"
    local part2Duration="${retval}"

    if [ ! -f "${destFolder}/export-titles-outro-padding.mkv" ]; then
        info "Converting \"export-titles-outro-padding.mp4\" to mkv container..."
        ffmpeg -y -i "${titleFilesLocation}/export-titles-outro-padding.mp4" -c copy "${destFolder}/export-titles-outro-padding.mkv"
    fi

    info "Converting \"${destFileWOPath}-part-0-title.mp4\" to mkv container..."
    ffmpeg -y -i "${titleFilesLocation}${destFileWOPath}-part-0-title.mp4" -c copy "${destFile}-part-0-title.mkv"
    info "Creating \"${destFile}-part-1.mkv\"..."
    ffmpeg -y -to 00:00:02 -i "${srcFile}" -c copy "${destFile}-part-1.mkv"
    # When used as an input option (before "-i"), seeks in this input file to
    # position. Note that in most formats it is not possible to seek exactly,
    # so ffmpeg will seek to the closest seek point before position. When
    # doing stream copy (our case), that additional gap will be preserved,
    # explaining why we start at 00:00:03 instead of 00:00:02.
    info "Creating \"${destFile}-part-2.mkv\"..."
    ffmpeg -y -ss 00:00:03 -to "${part2Duration}" -i "${srcFile}" -c copy "${destFile}-part-2.mkv"
    info "Creating \"${destFile}-part-3.mkv\"..."
    ffmpeg -y -sseof -00:00:02 -i "${srcFile}" -c copy "${destFile}-part-3.mkv"

    # We still have a PTS issue only at audio at the moment where both files
    # are reassembled:
    #
    # mpv 2021-09-30-0001-Opening-Session-Jan-Kendy-Holesovsky-final.mkv
    #  (+) Video --vid=1 (*) (h264 1920x1080 30.000fps)
    #  (+) Audio --aid=1 (*) (aac 2ch 48000Hz)
    # AO: [pulse] 48000Hz stereo 2ch float
    # VO: [gpu] 1920x1080 yuv420p
    # AV: 00:00:13 / 00:14:51 (2%) A-V: -0.000 ct: -0.064
    # Invalid audio PTS: 13.802667 -> 13.989000
    # AV: 00:00:13 / 00:14:51 (2%) A-V: -0.000 ct: -0.064
    # Invalid audio PTS: 13.802667 -> 13.989000
    # AV: 00:14:51 / 00:14:51 (100%) A-V:  0.000 ct:  0.091
    #
    # Exiting... (End of file)

    info "Adding fade in to \"${destFile}-part-1.mkv\""
    ffmpeg -y -i "${destFile}-part-1.mkv" -profile:v high -pix_fmt yuv420p -vf "fade=t=in:st=0:d=1:color=504999" -acodec copy "${destFile}-part-1-fade-in.mkv"
    info "Adding fade out to \"$destFile-part-3.mkv\""
    ffmpeg -y -i "${destFile}-part-3.mkv" -profile:v high -pix_fmt yuv420p -vf "fade=t=out:st=0:d=1:color=504999" -acodec copy "${destFile}-part-3-fade-out.mkv"
    {
        echo "file '${destFile}-part-0-title.mkv'"
        echo "file '${destFile}-part-1-fade-in.mkv'"
        echo "file '${destFile}-part-2.mkv'"
        echo "file '${destFile}-part-3-fade-out.mkv'"
        echo "file '${destFolder}/export-titles-outro-padding.mkv"
    } > input-concat.txt
    
    info "Merging files together to \"${destFile}-final.mkv\""
    # In order to avoid error messages like this one:
    #     Unsafe file name '../../titles-intro-outro/2021-09-30-0001-Opening-Session-Jan-Kendy-Holesovsky-part-0-title.mkv'
    #     input-concat.txt: Operation not permitted
    # we need to specify the argument `-safe 0` to ffmpeg
    # because in this use case the path is not considerd safe as it contains
    # a dot to start with.
    # > safe If set to 1, reject unsafe file paths. A file path is considered
    # > safe if it does not contain a protocol specification and is relative
    # > and all components only contain characters from the portable character
    # > set (letters, digits, period, underscore and hyphen) and have no
    # > period at the beginning of a component.
    # src.: https://stackoverflow.com/a/56029574/3514658
    ffmpeg -safe 0 -y -f concat -i input-concat.txt -c copy "${destFile}-final.mkv"
    info "Removing temp files..."
    rm -v "${destFile}-part-"{0,1,2,3}*".mkv"
    rm -v input-concat.txt
}

function usage() {
	printf "COOL-Days Video Extracter\n\n"
    printf "A simple command line tool to export the videos of the COOL-Days 2021\n\n"
	argsparse_usage
    exit
}

function main() {

    argsparse_use_option titles-folder "The folder containing the video titles"
    # The following lines can be set on the same line as the previous line.
    argsparse_set_option_property value titles-folder
    argsparse_set_option_property short:t titles-folder
    argsparse_set_option_property type:directory titles-folder
    argsparse_set_option_property mandatory titles-folder

    argsparse_use_option rushes-folder "The folder containing the video rushes"
    # The following lines can be set on the same line as the previous line.
    argsparse_set_option_property value rushes-folder
    argsparse_set_option_property short:r rushes-folder
    argsparse_set_option_property type:directory rushes-folder
    argsparse_set_option_property mandatory rushes-folder

    argsparse_use_option extracted-folder "The folder containing the extracted videos"
    # The following lines can be set on the same line as the previous line.
    argsparse_set_option_property value extracted-folder
    argsparse_set_option_property short:e extracted-folder
    argsparse_set_option_property type:directory extracted-folder
    argsparse_set_option_property mandatory extracted-folder

    argsparse_use_option skip-1 "Skip the video extraction from the initial rushes"
    # The following lines can be set on the same line as the previous line.
    argsparse_set_option_property value extracted-folder
    argsparse_set_option_property short:s skip-1

    argsparse_parse_options "$@"

    ###########################################################################
    # Step 1: Extract from rushes
    ###########################################################################

    if ! argsparse_is_option_set "skip-1"; then

    # COOL Days 2021 - Developers Day - Full day experience
    info "Extracting COOL Days 2021 - Developers Day - Full day experience..."
    # shellcheck disable=SC2154
    rushFile="${program_options["rushes-folder"]}/2021-09-30-03-15-56.mkv"
    extract_from_rush "$rushFile" "05:57:55" "        " "${program_options["extracted-folder"]}/2021-09-30-0000-COOL-Days-2021-Developers-Day-The-full-experience-part-1.mkv"

    rushFile="${program_options["rushes-folder"]}/2021-09-30-12-40-39.mkv"
    cp                "$rushFile"                       "${program_options["extracted-folder"]}/2021-09-30-0000-COOL-Days-2021-Developers-Day-The-full-experience-part-2.mkv"
    {
        echo "file '${program_options["extracted-folder"]}/2021-09-30-0000-COOL-Days-2021-Developers-Day-The-full-experience-part-1.mkv'"
        echo "file '${program_options["extracted-folder"]}/2021-09-30-0000-COOL-Days-2021-Developers-Day-The-full-experience-part-2.mkv'"
    } > input-concat.txt
    ffmpeg -safe 0 -y -f concat -i input-concat.txt -c copy "${program_options["extracted-folder"]}/2021-09-30-0000-COOL-Days-2021-Developers-Day-The-full-experience.mkv"
    info "Removing temp files..."
    rm -v "${program_options["extracted-folder"]}/2021-09-30-0000-COOL-Days-2021-Developers-Day-The-full-experience-part-"{1,2}".mkv"
    rm -v input-concat.txt

    info "Extracting Developers Day talks..."

    # Rush file 1 - 2021-09-30-03-15-56.mkv
    rushFile="${program_options["rushes-folder"]}/2021-09-30-03-15-56.mkv"
    extract_from_rush "$rushFile" "06:14:17" "00:14:38" "${program_options["extracted-folder"]}/2021-09-30-0001-Opening-Session-Jan-Kendy-Holesovsky.mkv"
    extract_from_rush "$rushFile" "06:32:56" "00:09:09" "${program_options["extracted-folder"]}/2021-09-30-0002-SDK-creating-a-new-integration-Marco-Cecchetti.mkv"
    extract_from_rush "$rushFile" "06:42:58" "00:10:02" "${program_options["extracted-folder"]}/2021-09-30-0003-Mobile-design-improvements-Pedro-Silva.mkv"
    extract_from_rush "$rushFile" "06:55:25" "00:06:37" "${program_options["extracted-folder"]}/2021-09-30-0004-Cypress-tests-howto-notebookbar-and-more-Rashesh-Padia.mkv"
    extract_from_rush "$rushFile" "07:02:58" "00:13:02" "${program_options["extracted-folder"]}/2021-09-30-0005-Canvas-for-rendering-UX-Gokay-Satir.mkv"
    extract_from_rush "$rushFile" "07:17:21" "00:05:52" "${program_options["extracted-folder"]}/2021-09-30-0006-Editing-simulation-Mert-Tumer.mkv"
    extract_from_rush "$rushFile" "07:24:04" "00:05:01" "${program_options["extracted-folder"]}/2021-09-30-0007-Kubernetes-setup-and-deployment-Pranam-Lashkari.mkv"
    extract_from_rush "$rushFile" "07:29:17" "00:27:05" "${program_options["extracted-folder"]}/2021-09-30-0008-QA-session-1.mkv"
    extract_from_rush "$rushFile" "08:00:10" "00:07:59" "${program_options["extracted-folder"]}/2021-09-30-0009-iOS-new-features-Tor-Lillqvist.mkv"
    extract_from_rush "$rushFile" "08:08:50" "00:04:44" "${program_options["extracted-folder"]}/2021-09-30-0010-Canvas-Overlays-and-Improvements-Dennis-Francis.mkv"
    extract_from_rush "$rushFile" "08:15:22" "00:11:52" "${program_options["extracted-folder"]}/2021-09-30-0011-How-COOL-is-used-in-1-and-1-Alexandru-Vladutu.mkv"
    extract_from_rush "$rushFile" "08:27:47" "00:06:38" "${program_options["extracted-folder"]}/2021-09-30-0012-Android-new-features-Mert-Tumer.mkv"
    extract_from_rush "$rushFile" "08:35:20" "00:10:02" "${program_options["extracted-folder"]}/2021-09-30-0013-Fuzzing-asan-string-vectors-Miklos-Vajna.mkv"
    extract_from_rush "$rushFile" "08:46:08" "00:15:23" "${program_options["extracted-folder"]}/2021-09-30-0014-Translating-Collabora-website-Rute-Correia.mkv"
    extract_from_rush "$rushFile" "09:01:55" "00:20:25" "${program_options["extracted-folder"]}/2021-09-30-0015-QA-session-2.mkv"

    # Rush file 2 - 2021-09-30-12-40-39.mkv
    rushFile="${program_options["rushes-folder"]}/2021-09-30-12-40-39.mkv"

    # Lunch
    # We don't care about the lunch. Just watch the full experience file if
    # you want to follow the chat.
    # extract_from_rush "$rushFile" "00:06:30" "00:00:58" "${program_options["extracted-folder"]}/2021-09-30-0016-Lunch.mkv"

    # Export 2021-09-30-0017-New-sidebar-and-dialog-backend-Szymon-Klos-fix
    ffmpeg -y -i "${program_options["rushes-folder"]}/../2021-09-30-0017-New-sidebar-and-dialog-backend-Szymon-Klos-fix/2021-09-30-0017-New-sidebar-and-dialog-backend-Szymon-Klos.mp4" -c copy "${program_options["extracted-folder"]}/2021-09-30-0017-New-sidebar-and-dialog-backend-Szymon-Klos.mkv"

    extract_from_rush "$rushFile" "00:44:57" "00:07:17" "${program_options["extracted-folder"]}/2021-09-30-0018-Collabora-Online-Forum-update-Mike-Kagansky.mkv"
    extract_from_rush "$rushFile" "00:52:37" "00:12:03" "${program_options["extracted-folder"]}/2021-09-30-0019-How-to-get-involved-in-translation-Andras-Timar.mkv"
    extract_from_rush "$rushFile" "01:06:55" "00:10:51" "${program_options["extracted-folder"]}/2021-09-30-0020-Stability-and-cleanup-improvements-in-Online-Gabriel-Masei.mkv"
    extract_from_rush "$rushFile" "01:18:30" "00:08:06" "${program_options["extracted-folder"]}/2021-09-30-0021-OOXML-document-analysis-Gulsah-Kose.mkv"
    extract_from_rush "$rushFile" "01:27:05" "00:09:20" "${program_options["extracted-folder"]}/2021-09-30-0022-Performance-improvements-Tor-Lillqvist.mkv"
    extract_from_rush "$rushFile" "01:36:31" "00:11:15" "${program_options["extracted-folder"]}/2021-09-30-0023-QA-session-3.mkv"
    extract_from_rush "$rushFile" "01:50:20" "00:12:45" "${program_options["extracted-folder"]}/2021-09-30-0024-Async-save-design-Ashod-Nakashian.mkv"
    extract_from_rush "$rushFile" "02:03:44" "00:13:41" "${program_options["extracted-folder"]}/2021-09-30-0025-Macro-Dialog-feature-Henry-Castro.mkv"
    extract_from_rush "$rushFile" "02:18:35" "00:12:01" "${program_options["extracted-folder"]}/2021-09-30-0026-Rendering-wasteage-and-performance-wins-Lubos-Lunak.mkv"
    extract_from_rush "$rushFile" "02:31:32" "00:15:08" "${program_options["extracted-folder"]}/2021-09-30-0027-Symfony-bundle-intergrating-WOPI-and-Collabora-Online-Pol-Dellaiera.mkv"
    extract_from_rush "$rushFile" "02:48:31" "00:09:51" "${program_options["extracted-folder"]}/2021-09-30-0028-Multi-page-PDF-viewing-Gokay-Satir.mkv"
    extract_from_rush "$rushFile" "02:59:00" "00:09:09" "${program_options["extracted-folder"]}/2021-09-30-0029-How-to-bisect-your-bug-to-a-single-patch-Nnamani-Ezinne.mkv"
    extract_from_rush "$rushFile" "03:08:52" "00:11:41" "${program_options["extracted-folder"]}/2021-09-30-0030-Desktop-design-improvements-Pedro-Silva.mkv"
    extract_from_rush "$rushFile" "03:20:34" "00:08:39" "${program_options["extracted-folder"]}/2021-09-30-0031-QA-session-4.mkv"
    extract_from_rush "$rushFile" "03:29:20" "00:09:05" "${program_options["extracted-folder"]}/2021-09-30-0032-User-sentiment-reporting-Pedro-Silva.mkv"
    extract_from_rush "$rushFile" "03:39:07" "00:06:25" "${program_options["extracted-folder"]}/2021-09-30-0033-Setting-up-your-own-Collabora-Online-Michael-Meeks.mkv"
    extract_from_rush "$rushFile" "03:46:10" "00:09:58" "${program_options["extracted-folder"]}/2021-09-30-0034-Easy-hacks-to-get-involved-Jan-Kendy-Holesovsky.mkv"
    extract_from_rush "$rushFile" "03:56:29" "00:10:00" "${program_options["extracted-folder"]}/2021-09-30-0035-Community-website-how-to-edit-it-Pedro-Silva.mkv"
    extract_from_rush "$rushFile" "04:10:38" "00:10:30" "${program_options["extracted-folder"]}/2021-09-30-0036-Notebookbar-Structure-Andreas-Kainz.mkv"
    extract_from_rush "$rushFile" "04:22:10" "00:10:30" "${program_options["extracted-folder"]}/2021-09-30-0037-Document-searching-Tomaz-Vajngerl.mkv"
    extract_from_rush "$rushFile" "04:32:46" "00:04:22" "${program_options["extracted-folder"]}/2021-09-30-0038-QA-session-5.mkv"

    # Export 2021-09-30-0039-Nextcloud-integration-update-Julius-Hartl-fix
    ffmpeg -y -i "${program_options["rushes-folder"]}/../2021-09-30-0039-Nextcloud-integration-update-Julius-Hartl-fix/2021-09-30-0039-Nextcloud-integration-update-Julius-Hartl.mp4" -c copy "${program_options["extracted-folder"]}/2021-09-30-0039-Nextcloud-integration-update-Julius-Hartl.mkv"

    extract_from_rush "$rushFile" "04:48:49" "00:12:30" "${program_options["extracted-folder"]}/2021-09-30-0040-EGroupware-integration-update-Birgit-Becker.mkv"
    extract_from_rush "$rushFile" "05:02:25" "00:04:47" "${program_options["extracted-folder"]}/2021-09-30-0041-Mattermost-integration-update-Chetanya-Kandhari.mkv"
    extract_from_rush "$rushFile" "05:08:38" "00:08:10" "${program_options["extracted-folder"]}/2021-09-30-0042-Moodle-integration-update-Ashod-Nakashian.mkv"
    extract_from_rush "$rushFile" "05:17:44" "00:09:23" "${program_options["extracted-folder"]}/2021-09-30-0043-Collabora-Online-and-WOPI-in-ownCloud-Infinite-Scale-Willy-Kloucek.mkv"
    extract_from_rush "$rushFile" "05:27:07" "00:08:03" "${program_options["extracted-folder"]}/2021-09-30-0044-QA-session-6.mkv"
    extract_from_rush "$rushFile" "05:35:29" "00:06:49" "${program_options["extracted-folder"]}/2021-09-30-0045-Closing-session-Michael-Meeks.mkv"

    # Rush file 3 - 2021-10-01-09-57-57.mkv
    info "Extracting COOL Days 2021 - Business Day - Full day experience..."
    rushFile="${program_options["rushes-folder"]}/2021-10-01-09-57-57.mkv"
    cp                "$rushFile"                       "${program_options["extracted-folder"]}/2021-10-01-0000-COOL-Days-2021-Business-Day-The-full-experience.mkv"

    info "Extracting Business Day talks..."
    extract_from_rush "$rushFile" "00:02:20" "00:03:06" "${program_options["extracted-folder"]}/2021-10-01-0001-Welcome-to-the-first-COOL-Days-Business-Day-Cor-Nouws.mkv"
    extract_from_rush "$rushFile" "00:05:35" "00:21:17" "${program_options["extracted-folder"]}/2021-10-01-0002-Safe-Powerful-Flexible-how-Collabora-Online-challenges-Big-Tech-Michael-Meeks.mkv"
    extract_from_rush "$rushFile" "00:27:37" "00:11:19" "${program_options["extracted-folder"]}/2021-10-01-0003-Interoperable-on-premise-collaborative-editing-Enterprise-benefits-of-Collabora-Online-Eloy-Crespo.mkv"
    extract_from_rush "$rushFile" "00:39:39" "00:14:07" "${program_options["extracted-folder"]}/2021-10-01-0004-Bulletproof-collaboration-How-Collabora-Online-hardens-the-security-of-your-documents-Miklos-Vajna.mkv"
    extract_from_rush "$rushFile" "00:54:22" "00:16:20" "${program_options["extracted-folder"]}/2021-10-01-0005-Easy-to-set-up-Anywhere-Integrating-Collabora-Online-into-your-services-Jan-Holesovsky.mkv"

    # Break
    extract_from_rush "$rushFile" "01:22:28" "00:38:08" "${program_options["extracted-folder"]}/2021-10-01-0006-Independents-reflections-on-alternatives-to-big-tech-Audience.mkv"
    extract_from_rush "$rushFile" "02:01:10" "00:32:40" "${program_options["extracted-folder"]}/2021-10-01-0007-QA-session.mkv"

    # Lunch
    extract_from_rush "$rushFile" "03:22:14" "00:20:37" "${program_options["extracted-folder"]}/2021-10-01-0008-ownCloud-RandD-Sales-collaboration-with-SecureView-Patrick-Maier.mkv"
    extract_from_rush "$rushFile" "03:44:08" "00:15:34" "${program_options["extracted-folder"]}/2021-10-01-0009-SIB-secure-collaboration-with-Nextcloud-and-Collabora-at-French-schools-Jos-Poortvliet.mkv"
    extract_from_rush "$rushFile" "04:02:38" "00:12:44" "${program_options["extracted-folder"]}/2021-10-01-0010-Large-public-institutions-across-France-benefit-from-Arawa-s-expertise-Philippe-Hemmel.mkv"
    extract_from_rush "$rushFile" "04:16:10" "00:16:45" "${program_options["extracted-folder"]}/2021-10-01-0011-SURFdrive-a-large-scale-secure-environment-Jean-Marie-de-Boer.mkv"
    extract_from_rush "$rushFile" "04:33:22" "00:17:54" "${program_options["extracted-folder"]}/2021-10-01-0012-EGroupware-a-smart-online-office-integration-Birgit-Becker.mkv"
    extract_from_rush "$rushFile" "04:51:49" "00:13:10" "${program_options["extracted-folder"]}/2021-10-01-0013-LibreOffice-Technology-a-FOSS-platform-for-personal-productivity-Italo-Vignoli.mkv"
    extract_from_rush "$rushFile" "05:05:15" "00:01:40" "${program_options["extracted-folder"]}/2021-10-01-0014-European-Pirate-Party-Being-in-control-of-the-own-documents-and-data-Mikulas-Peksa.mkv"
    extract_from_rush "$rushFile" "05:07:54" "00:09:33" "${program_options["extracted-folder"]}/2021-10-01-0015-Students-get-a-richer-Moodle-e-learning-experience-with-Collabora-Online-integrated-Davo-Smith.mkv"
    extract_from_rush "$rushFile" "05:18:15" "00:02:35" "${program_options["extracted-folder"]}/2021-10-01-0016-Discussion-and-Feedback-Michael-Meeks.mkv"
    extract_from_rush "$rushFile" "05:21:05" "00:04:00" "${program_options["extracted-folder"]}/2021-10-01-0017-Closing-Michael-Meeks.mkv"

    fi

    ###########################################################################
    # Step 2: Split for fade in/fade out and concat
    ###########################################################################

    # The mkv container is using a framerate database called DTS to store the
    # time afterwhich to display images. However when concatening mkv files,
    # different timebases are joined, the result won't be correct since ffmpeg
    # will adopt the timebase of the first video as the definitive value and
    # this will lead to the error "Non-monotonous DTS in output stream",
    # leading in our case to extra images being randomly added (1000 images
    # leading to sometimes 30 seconds of image that is not changing).
    #
    # Even a reencoding process of all the videos when concatening them was not
    # fixing the issue, and worse, it was degrating the video quality.
    #
    # The only solution is to use a more recent kind of container which is
    # using timestamp instead (mkv)
    #
    # src.: https://stackoverflow.com/a/6044365
    # src.: https://stackoverflow.com/questions/43333542/x/43337235
    # src.: https://superuser.com/questions/1150276/x

    # Using this script is required as KDEnlive is not allowing to have fading
    # from/to a specific color

    for i in "${program_options["extracted-folder"]}/"*.mkv; do
        # arg1= srcFile
        # arg2= titleFilesLocation
        create_final_video "$i" "${program_options["titles-folder"]}"
    done
    info "Removing \"export-titles-outro-padding.mkv\"..."
    rm -v "${program_options["extracted-folder"]}/export-titles-outro-padding.mkv"
}

main "$@"
