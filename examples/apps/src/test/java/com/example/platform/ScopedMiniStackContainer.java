package com.example.platform;

import org.ministack.testcontainers.MiniStackContainer;

/**
 * MiniStack 0.1.5 stop() reaps ALL containers carrying the `ministack` label.
 * These tests do not enable MiniStack sidecars, so remove only this owned container.
 * PostgreSQL/MySQL fixtures have their own Testcontainers lifecycles.
 */
final class ScopedMiniStackContainer extends MiniStackContainer {
    ScopedMiniStackContainer() { super("1.5.27"); }
    @Override public void stop() {
        String id=getContainerId();
        if(id==null)return;
        try { getDockerClient().removeContainerCmd(id).withForce(true).withRemoveVolumes(true).exec(); }
        catch(com.github.dockerjava.api.exception.NotFoundException alreadyRemoved) { /* Idempotent own-container cleanup. */ }
    }
}
