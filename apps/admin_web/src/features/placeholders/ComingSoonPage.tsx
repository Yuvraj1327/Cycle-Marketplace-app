import { useLocation } from 'react-router-dom'
import { PLACEHOLDER_TITLES } from '../../components/layout/nav'
import { PageHeader } from '../../components/layout/PageHeader'
import { Card, EmptyState } from '../../components/common/ui'

/** Navigation placeholder for modules that are built in the next development phase. It shows no data and calls no APIs. */
export function ComingSoonPage() {
  const { pathname } = useLocation()
  const title = PLACEHOLDER_TITLES['/' + pathname.split('/')[1]] ?? 'This section'
  return (
    <>
      <PageHeader title={title} crumbs={[{ label: 'Overview', to: '/' }, { label: title }]} />
      <Card>
        <EmptyState title={`${title} management is coming next`} message="This module is planned for the next development phase. Nothing here is functional yet." />
      </Card>
    </>
  )
}

export function NotFoundPage() {
  return (
    <Card>
      <EmptyState title="Page not found" message="That address does not exist in the admin console." />
    </Card>
  )
}
