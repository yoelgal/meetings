import { registerProresDecoder } from '@mediabunny/prores';
import { registerRoot } from 'remotion';
import { RemotionRoot } from './Root';

// The two app clips are ProRes 4444, which is the only ProRes profile that carries an alpha channel —
// and the alpha is what lets the film composite the window's real rounded corners over its own
// backdrop. WebCodecs has no native ProRes decoder, so `<Video>` refuses the file until this is
// registered, and it must happen before `registerRoot`.
//
// The alternative was transcoding the clips to VP9-with-alpha, which Chrome decodes natively and
// faster. It is also lossy, and the thing being compressed is 10pt UI text on a dark background —
// exactly the content a video codec is worst at. Keeping the master lossless costs render time and
// nothing else.
registerProresDecoder();

registerRoot(RemotionRoot);
