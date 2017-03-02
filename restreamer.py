import sys
import os
import subprocess
import json
import signal

import logging
import logging.handlers

logger = logging.getLogger()
logger.setLevel(logging.DEBUG)

#handler = logging.handlers.SysLogHandler(address='/var/run/syslog' if sys.platform == 'darwin' else '/dev/log')
handler = logging.FileHandler('/tmp/restreamerpy.log')
logger.addHandler(handler)


class TermHandler(object):
    def __init__(self):
        self.should_exit = False
        signal.signal(signal.SIGINT, self.exit_gracefully)
        signal.signal(signal.SIGTERM, self.exit_gracefully)

    def exit_gracefully(self, signum, frame):
        self.should_exit = True


def popen(args):
    line_buffered = 1
    p = subprocess.Popen(args,
                         shell=False,
                         bufsize=line_buffered,
                         stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT,
                         close_fds=True)
    p.stdin.close()
    return p


def ffmpeg_restream(input="rtmp://localhost/src/mystream",
                    output="rtmp://localhost/dst/mystream1"):
    ffmpeg_bin = os.environ.get('PATH_FFMPEG', 'ffmpeg')
    return [ffmpeg_bin, "-re",
            "-i", input, "-acodec", "copy", "-vcodec", "copy",
            "-f", "flv", output]


def run_loop(source, list_of_targets):
    ps = {target: popen(ffmpeg_restream(source, target))
          for target in list_of_targets}
    term = TermHandler()
    while True:
        if term.should_exit:
            for _, p in ps.iteritems():
                p.terminate()
            break

        for target, p in ps.iteritems():
            if p.poll() is not None:
                logger.warn('{} exited with code {}, restarting'.format(
                  target, p.returncode))
                ps[target] = popen(ffmpeg_restream(source, target))
                continue
            contents = p.stdout.readline()
            logger.info('[%s]: %s' % (target, contents.strip()))


def main():
    source = sys.argv[1]
    targets_file = os.environ.get('PATH_TARGETS', '/tmp/targets')
    # assume targets is a json file that maps sources to outputs
    if not os.path.isfile(targets_file):
        logger.error('restreamer: no targets file {} found'.format(
          targets_file))
        sys.exit(1)
    with open(targets_file) as f:
        mapping = json.load(f)
    list_of_targets = mapping.get(source)
    if not isinstance(list_of_targets, list):
        list_of_targets = [list_of_targets]
    if not list_of_targets:
        logger.error('restreamer mapping not found for {}, mapping: {}'.format(
          source, mapping))
        sys.exit(2)
    else:
        logger.info('restreamer starting for {}, mapping: {}'.format(
          source, mapping))
    return run_loop(source, list_of_targets)


if __name__ == '__main__':
    try:
        main()
    except:
        logger.exception('crashed {}'.format(sys.argv[1:]))
