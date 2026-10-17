package cn.apt.rootaudio;

/** Fixed cross-language upload keys: transport identity must survive App/root retries. */
public final class RootUploadIdentityTest {
    private static int checks;
    private interface Attempt { void run() throws Exception; }
    private static void check(boolean value) { checks++; if (!value) throw new AssertionError("upload identity"); }
    private static void refused(Attempt attempt) throws Exception {
        try { attempt.run(); } catch (IllegalArgumentException expected) { checks++; return; }
        throw new AssertionError("invalid upload identity accepted");
    }
    public static void main(String[] args) throws Exception {
        String capture="00000000-0000-4000-8000-000000000001", matter="00000000-0000-4000-8000-000000000002";
        String client="00000000-0000-4000-8000-000000000003", sha=new String(new char[64]).replace('\0','a');
        check(RootUploadIdentity.piece(capture,0).equals("e64640c3-b3b6-a40e-62d6-894da002acaf"));
        check(RootUploadIdentity.piece(capture,1).equals("8a1096da-255e-19de-9967-5cecc9447a08"));
        check(RootUploadIdentity.piece(capture,8640).equals("bffbd677-f203-1cd6-2f46-a9e1673ef310"));
        check(RootUploadIdentity.key(client,matter,capture,0,sha).equals("stepx/"+client+"/"+matter+"/e64640c3-b3b6-a40e-62d6-894da002acaf-"+sha+".wav"));
        refused(()->RootUploadIdentity.piece(capture,-1)); refused(()->RootUploadIdentity.piece(capture,8641));
        refused(()->RootUploadIdentity.piece("../capture",0)); refused(()->RootUploadIdentity.uuid(null));
        refused(()->RootUploadIdentity.key(client,matter,capture,0,sha.toUpperCase()));
        refused(()->RootUploadIdentity.key("../client",matter,capture,0,sha));
        refused(()->RootUploadIdentity.key(client,"../matter",capture,0,sha));
        System.out.println("ROOT_UPLOAD_IDENTITY_OK checks="+checks);
    }
}
