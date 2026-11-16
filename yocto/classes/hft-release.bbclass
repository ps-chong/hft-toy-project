# Refuses to parse a release build (HFT_RELEASE = "1") that is not pinned,
# signed and hardened. yocto/kas/release.yml inherits it globally.
#
# A release is an image somebody may install on a board, so the checks run when
# the configuration is parsed, before any task: a missing signing key would
# otherwise surface hours into the build, and an unpinned HFT_SRCREV would
# silently build whatever develop points to that day.

python hft_release_check() {
    import os
    import re

    if d.getVar('HFT_RELEASE') != '1':
        return

    problems = []

    # Unexpanded, so the default "${AUTOREV}" is seen for what it is.
    srcrev = (d.getVar('HFT_SRCREV', False) or '').strip()
    if not re.fullmatch(r'[0-9a-f]{40}', srcrev):
        problems.append(
            "HFT_SRCREV is '%s'; set it to the 40-character hash of the commit "
            "to release (AUTOREV follows the tip of develop)" % srcrev)

    if d.getVar('HFT_SWUPDATE_SIGNING') != '1':
        problems.append('HFT_SWUPDATE_SIGNING must be "1"')
    for name in ('HFT_SWUPDATE_PRIVATE_KEY', 'HFT_SWUPDATE_CERTIFICATE',
                 'HFT_SWUPDATE_PUBLIC_CERT'):
        path = d.getVar(name) or ''
        if not os.path.isfile(path):
            problems.append("%s must name an existing file (it is '%s')" % (name, path))

    if 'debug-tweaks' in (d.getVar('EXTRA_IMAGE_FEATURES') or '').split():
        problems.append('debug-tweaks (an empty root password) is still enabled')

    if problems:
        bb.fatal('Release build refused:\n  - ' + '\n  - '.join(problems))
}
hft_release_check[eventmask] = "bb.event.ConfigParsed"
addhandler hft_release_check
