import React, { createContext, useContext } from 'react';
import { createRoot } from 'react-dom/client';
import { StoreApi, useStore } from 'zustand';
import { WorkflowState, createWorkflowStore, WorkflowProps } from './store';

import WorkflowDiagram from '../workflow-diagram/WorkflowDiagram'

type Store = ReturnType<typeof createWorkflowStore>;
type Workflow = Pick<WorkflowProps, 'jobs' | 'edges' | 'triggers'>;

// This will take a store passed from the server and do some light transformation
// Specifically it identifies placeholder nodes
const identifyPlaceholders = (store: Store) => {
  const { jobs, triggers, edges } = store;
  
  const newJobs = jobs.map((item) => {
    if (!item.name && !item.expression) {
      return {
        ...item,
        placeholder: true
      }
    }
    return item;
  });
  
  const newEdges = edges.map((edge) => {
    const target = newJobs.find(({ id }) => edge.target_job_id === id);
    if (target?.placeholder) {
      return {
        ...edge,
        placeholder: true
      }
    }
    return edge;
  });

  const result = {
    triggers,
    jobs: newJobs,
    edges: newEdges,
  }

  return result;
}

export function mount(
  el: Element | DocumentFragment,
  workflowStore: Store,
  onSelectionChange: (id?: string) => void
) {
  const componentRoot = createRoot(el);

  function unmount() {
    unsubscribe();
    return componentRoot.unmount();
  }

  function render(model: Workflow) {
    const { add } = workflowStore.getState();

    const handleSelectionChange = (id: string) => {
      onSelectionChange?.(id);
    }

    const handleRequestChange = (diff) => {
      add(diff)
    }

    componentRoot.render(
      // TODO listen to change events from the diagram and upadte the store accordingly
      <WorkflowDiagram
        ref={el}
        workflow={identifyPlaceholders(model)}
        onSelectionChange={handleSelectionChange}
        requestChange={handleRequestChange}/>
    );
  }

  const unsubscribe = workflowStore.subscribe(render)

  return { unmount, render };
}